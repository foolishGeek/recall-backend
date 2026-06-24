// Feature: embed [D-EF-4]. No LLM. Chunk extracted_text, embed with
// text-embedding-3-small, replace node_chunks. Counts as 1 AI request; skipped
// silently when there's no text or the gate blocks the owner [D-AI-3].

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { chunkText } from "../../_shared/chunk.ts";
import { stripHtml } from "../../_shared/text.ts";
import { openaiEmbed } from "../../_shared/providers/openai.ts";
import { gateConsume, logUsage } from "../../_shared/quota.ts";
import { requireUuid } from "../../_shared/validate.ts";

export interface EmbedResult {
  chunks_upserted: number;
  skipped: boolean;
}

export async function embed(payload: Record<string, unknown>, config: AppConfig): Promise<EmbedResult> {
  const nodeId = requireUuid(payload.node_id, "node_id");
  const db = adminClient();

  const { data: node } = await db
    .from("nodes")
    .select("id, extracted_text, buckets!inner(user_id, deleted_at)")
    .eq("id", nodeId)
    .is("deleted_at", null)
    .maybeSingle();

  if (!node) return { chunks_upserted: 0, skipped: true };

  const owner = (node as { buckets?: { user_id?: string } }).buckets?.user_id;
  const text = stripHtml((node as { extracted_text?: string }).extracted_text);
  if (!owner || !text) return { chunks_upserted: 0, skipped: true };

  // Counts as 1 AI request; a blocked owner means we silently skip.
  const decision = await gateConsume(owner, "embed");
  if (!decision.allowed) return { chunks_upserted: 0, skipped: true };

  const chunks = chunkText(
    text,
    config.int("ai_chunk_size_tokens", 500),
    config.int("ai_chunk_overlap_tokens", 50),
  );
  if (chunks.length === 0) return { chunks_upserted: 0, skipped: true };

  const embedModel = config.str("ai_model_embed", "text-embedding-3-small");
  const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  const { embeddings, inputTokens } = await openaiEmbed(openaiKey, embedModel, chunks);

  // Replace old chunks atomically enough for our needs (delete then insert).
  await db.from("node_chunks").delete().eq("node_id", nodeId);

  const rows = chunks.map((content, i) => ({
    node_id: nodeId,
    chunk_index: i,
    content,
    // pgvector expects the bracketed text form; stringify the float array.
    embedding: JSON.stringify(embeddings[i] ?? []),
  }));

  const { error: insErr } = await db.from("node_chunks").insert(rows);
  if (insErr) throw insErr;

  await logUsage(owner, "embed", inputTokens, 0, embedModel);
  return { chunks_upserted: rows.length, skipped: false };
}
