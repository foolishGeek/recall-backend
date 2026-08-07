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
import { logInteraction } from "./interactions.ts";

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

export interface EmbedOptions {
  /**
   * False for a reindex — rebuilding vectors for content the user already paid
   * to embed. Charging again for our own improvement would spend a free user's
   * whole monthly allowance the moment a better chunker or model ships.
   */
  meter?: boolean;
  /** Why this ran ('content_change' | 'reindex'), recorded for provenance. */
  reason?: string;
}

export async function embedNode(
  nodeId: string,
  config: AppConfig,
  options: EmbedOptions = {},
): Promise<EmbedResult> {
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

  const work = async () => {
    const t0 = Date.now();
    const inputs = chunks.map((chunk) => `${headerOf(chunk)}${chunk.content}`);
    const { embeddings, inputTokens, model: usedModel, provider } = await embedTexts(config, inputs);

    const rows = chunks.map((chunk, i) => ({
      chunk_index: i,
      content: chunk.content,
      context_header: headerOf(chunk).trim(),
      token_count: counter.exact ? counter.count(inputs[i]) : null,
      embedding: embeddings[i] ?? [],
    }));

    const upserted = await replaceChunks(nodeId, rows);

    // Embedding is logged like every other feature so the vector corpus has the
    // same provenance as the answers: which model, which chunker, why it ran.
    await logInteraction({
      userId: owner,
      feature: "embed",
      scope: { kind: "nodes", ids: [nodeId] },
      retrievedNodeIds: [nodeId],
      model: usedModel,
      provider,
      latencyMs: Date.now() - t0,
      inputTokens,
      scopeKind: "nodes",
      payload: {
        reason: options.reason ?? (options.meter === false ? "reindex" : "content_change"),
        chunks: upserted,
        chunk_tokens: rows.map((r) => r.token_count),
        exact_tokens: counter.exact,
      },
    });

    return {
      result: { chunks_upserted: upserted, skipped: false },
      model: usedModel,
      provider,
      inputTokens,
    };
  };

  // A reindex is our own work on content already paid for, so it runs unmetered.
  if (options.meter === false) return (await work()).result;

  // Otherwise it counts as 1 AI request against the owner, and a blocked owner is
  // skipped silently since this is background work they never asked for [D-AI-3].
  // A provider or write failure releases the hold instead of charging them.
  const result = await withOptionalMeteredRequest({ userId: owner, feature: "embed" }, work);
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
