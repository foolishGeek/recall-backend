// Persist the retrieval candidate set for one interaction.
//
// The winners alone are almost useless for training a retriever: what teaches a
// reranker is which chunks were considered and passed over. So every candidate
// is written with its scores and a `used` flag saying whether it actually made
// it into the prompt.
//
// Best-effort by design — capture must never break an answer.

import { adminClient } from "./supabase.ts";
import { RetrieveResult } from "./retrieve.ts";

export async function captureRetrieval(
  interactionId: string | null,
  retrieved: RetrieveResult | null,
): Promise<void> {
  if (!interactionId || !retrieved || retrieved.candidates.length === 0) return;

  const usedChunks = new Set(
    retrieved.context.used.map((c) => c.chunk_id ?? `${c.node_id}:${c.content.length}`),
  );

  const payload = retrieved.candidates.map((c, i) => ({
    rank: i + 1,
    source_kind: c.source_kind ?? "node",
    source_id: c.source_id ?? c.node_id,
    chunk_id: c.chunk_id ?? null,
    vector_score: c.vector_score ?? null,
    keyword_score: c.keyword_score ?? null,
    rerank_score: c.rerank_score ?? null,
    used: usedChunks.has(c.chunk_id ?? `${c.node_id}:${c.content.length}`),
  }));

  try {
    const { error } = await adminClient().rpc("ai_log_retrieval_candidates", {
      p_interaction: interactionId,
      p_candidates: payload,
    });
    if (error) console.error("ai_log_retrieval_candidates failed:", error.message);
  } catch (e) {
    console.error("ai_log_retrieval_candidates threw:", (e as Error).message);
  }
}
