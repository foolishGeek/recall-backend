// RAG context formatting [AI-PROMPTS.md § Context formatting]:
// (1) keep up to maxChunksPerNode per note (highest similarity first),
// (2) sort remaining by similarity desc so strong hits lead,
// (3) trim total to ai_context_max_chars,
// (4) join blocks with "\n---\n". Each block is tagged with node id + title.
//
// The old "one chunk per note" rule silently starved long PDFs: a 60-page
// note could contribute one snippet no matter how relevant the rest was.
// Diversity here is the per-note cap — eight hits cannot all come from one
// note once maxChunksPerNode is small relative to top_k.

export interface RetrievedChunk {
  node_id: string;
  title: string;
  content: string;
  similarity: number;
  chunk_id?: string;
  vector_score?: number;
  keyword_score?: number;
  rerank_score?: number;
}

export interface FormattedContext {
  text: string;
  nodes: { node_id: string; title: string; snippet: string }[];
  /** Chunks that actually made it into the prompt, in prompt order. */
  used: RetrievedChunk[];
}

export interface FormatOptions {
  maxChars: number;
  /** Max chunks from any single note. Defaults to 3. */
  maxChunksPerNode?: number;
}

export function formatContext(
  chunks: RetrievedChunk[],
  opts: FormatOptions | number,
): FormattedContext {
  const maxChars = typeof opts === "number" ? opts : opts.maxChars;
  const maxPerNode = Math.max(
    1,
    typeof opts === "number" ? 3 : (opts.maxChunksPerNode ?? 3),
  );

  const ordered = diversify(chunks, maxPerNode);

  const blocks: string[] = [];
  const nodes: { node_id: string; title: string; snippet: string }[] = [];
  const used: RetrievedChunk[] = [];
  const seenNode = new Set<string>();
  let usedChars = 0;

  for (const c of ordered) {
    const block = `[Node: ${c.title || "Untitled"} | id:${c.node_id}]\n${c.content}`;
    const addition = (blocks.length ? 5 : 0) + block.length; // "\n---\n" join cost
    if (usedChars + addition > maxChars) break;
    blocks.push(block);
    usedChars += addition;
    used.push(c);
    if (!seenNode.has(c.node_id)) {
      seenNode.add(c.node_id);
      nodes.push({
        node_id: c.node_id,
        title: c.title,
        snippet: c.content.slice(0, 120),
      });
    }
  }

  return { text: blocks.join("\n---\n"), nodes, used };
}

/** Keep the strongest chunks per note, then order by similarity. */
export function diversify(
  chunks: RetrievedChunk[],
  maxChunksPerNode: number,
): RetrievedChunk[] {
  const byNode = new Map<string, RetrievedChunk[]>();
  for (const c of chunks) {
    const list = byNode.get(c.node_id) ?? [];
    list.push(c);
    byNode.set(c.node_id, list);
  }

  const kept: RetrievedChunk[] = [];
  for (const list of byNode.values()) {
    list.sort((a, b) => b.similarity - a.similarity);
    kept.push(...list.slice(0, maxChunksPerNode));
  }
  return kept.sort((a, b) => b.similarity - a.similarity);
}
