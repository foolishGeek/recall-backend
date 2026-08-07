// Embeds one note: chunk its extracted text, embed each chunk, and replace the
// note's chunks in a single transaction.
//
// Shared because two callers need it — the ai-forge `embed` feature and the
// embed-drain cron worker — and neither should own it.
//
// Each chunk is embedded with a short context header naming its bucket, note and
// section. Retrieval is a similarity search over these vectors, so a chunk that
// reads "it peaks in March" is unfindable unless the vector also knows the note
// is about rainfall. The header is stored apart from the body so citations still
// quote the note's own words.

import { adminClient } from "./supabase.ts";
import { AppConfig } from "./config.ts";
import { Chunk, chunkDocument } from "./chunk.ts";
import { stripHtml } from "./text.ts";
import { embedTexts, resolveEmbedModel } from "./providers/embed.ts";
import { tokenCounter } from "./tokens.ts";
import { withOptionalMeteredRequest } from "./quota.ts";

export interface EmbedResult {
  chunks_upserted: number;
  skipped: boolean;
}

/** Room left for the per-chunk section heading in the context header. */
const HEADING_TOKEN_ALLOWANCE = 24;

interface NodeRow {
  id: string;
  title: string | null;
  extracted_text: string | null;
  buckets?: { user_id?: string; name?: string | null } | null;
}

function contextHeader(
  bucket: string | null | undefined,
  title: string | null,
  heading: string | null,
): string {
  const parts = [bucket?.trim(), title?.trim(), heading?.trim()].filter(Boolean);
  return parts.length ? `${parts.join(" › ")}\n\n` : "";
}

export async function embedNode(nodeId: string, config: AppConfig): Promise<EmbedResult> {
  const db = adminClient();

  const { data, error } = await db
    .from("nodes")
    .select("id, title, extracted_text, buckets!inner(user_id, name, deleted_at)")
    .eq("id", nodeId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) throw error;

  const node = data as NodeRow | null;
  const owner = node?.buckets?.user_id;
  if (!node || !owner) return { chunks_upserted: 0, skipped: true };

  const text = stripHtml(node.extracted_text ?? undefined);

  // Text cleared but chunks still present: drop them, or the note keeps turning
  // up in search under content it no longer has. Costs nothing, so no metering.
  if (!text) {
    await replaceChunks(nodeId, []);
    return { chunks_upserted: 0, skipped: true };
  }

  const model = resolveEmbedModel(config);
  const counter = await tokenCounter(model.id);
  const headerOf = (chunk: Chunk) =>
    contextHeader(node.buckets?.name, node.title, chunk.heading);

  // Each chunk's header also names its section heading, which is not known until
  // the document has been split, so the bucket and title are measured and the
  // heading gets a flat allowance.
  const baseHeader = contextHeader(node.buckets?.name, node.title, null);

  const chunks = chunkDocument(text, {
    sizeTokens: config.int("ai_chunk_size_tokens", 500),
    overlapTokens: config.int("ai_chunk_overlap_tokens", 50),
    minTokens: config.int("ai_chunk_min_tokens", 48),
    reserveTokens: counter.count(baseHeader) + HEADING_TOKEN_ALLOWANCE,
    count: counter.count,
  });
  if (chunks.length === 0) return { chunks_upserted: 0, skipped: true };

  // Counts as 1 AI request against the owner; a blocked owner is skipped
  // silently since this is background work they never asked for [D-AI-3].
  // A provider or write failure releases the hold instead of charging them.
  const result = await withOptionalMeteredRequest({ userId: owner, feature: "embed" }, async () => {
    const inputs = chunks.map((chunk) => `${headerOf(chunk)}${chunk.content}`);
    const { embeddings, inputTokens, model: usedModel, provider } = await embedTexts(config, inputs);

    const rows = chunks.map((chunk, i) => ({
      chunk_index: i,
      content: chunk.content,
      context_header: headerOf(chunk).trim(),
      token_count: counter.exact ? counter.count(inputs[i]) : null,
      embedding: embeddings[i] ?? [],
    }));

    return {
      result: { chunks_upserted: await replaceChunks(nodeId, rows), skipped: false },
      model: usedModel,
      provider,
      inputTokens,
    };
  });

  return result ?? { chunks_upserted: 0, skipped: true };
}

interface ChunkRow {
  chunk_index: number;
  content: string;
  context_header: string;
  token_count: number | null;
  embedding: number[];
}

/** One transaction, so a note is never left observably chunk-less. */
async function replaceChunks(nodeId: string, rows: ChunkRow[]): Promise<number> {
  const { data, error } = await adminClient().rpc("node_chunks_replace", {
    p_node_id: nodeId,
    p_chunks: rows,
  });
  if (error) throw error;
  return (data as number | null) ?? 0;
}
