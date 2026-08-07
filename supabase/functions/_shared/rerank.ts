// Pass-through rerank seam. Retrieve-wide → rerank → trim is the pipeline;
// today this returns the same order so behaviour does not change. Later it
// holds our own cross-encoder trained from ai_retrieval_candidates.

import { RetrievedChunk } from "./context.ts";

export interface RerankInput {
  query: string;
  candidates: RetrievedChunk[];
  topK: number;
}

export function rerank(input: RerankInput): RetrievedChunk[] {
  const ordered = [...input.candidates].sort((a, b) => {
    const as = a.rerank_score ?? a.similarity;
    const bs = b.rerank_score ?? b.similarity;
    return bs - as;
  });
  return ordered.slice(0, Math.max(1, input.topK));
}
