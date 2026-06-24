// RAG context formatting [AI-PROMPTS.md § Context formatting]:
// (1) dedupe by node_id keeping the highest-similarity chunk,
// (2) sort by similarity desc, (3) trim total to ai_context_max_chars,
// (4) join blocks with "\n---\n". Each block is tagged with node id + title.

export interface RetrievedChunk {
  node_id: string;
  title: string;
  content: string;
  similarity: number;
}

export interface FormattedContext {
  text: string;
  nodes: { node_id: string; title: string; snippet: string }[];
}

export function formatContext(
  chunks: RetrievedChunk[],
  maxChars: number,
): FormattedContext {
  const best = new Map<string, RetrievedChunk>();
  for (const c of chunks) {
    const prev = best.get(c.node_id);
    if (!prev || c.similarity > prev.similarity) best.set(c.node_id, c);
  }

  const ordered = [...best.values()].sort((a, b) => b.similarity - a.similarity);

  const blocks: string[] = [];
  const nodes: { node_id: string; title: string; snippet: string }[] = [];
  let used = 0;

  for (const c of ordered) {
    const block = `[Node: ${c.title || "Untitled"} | id:${c.node_id}]\n${c.content}`;
    const addition = (blocks.length ? 5 : 0) + block.length; // "\n---\n" join cost
    if (used + addition > maxChars) break;
    blocks.push(block);
    used += addition;
    nodes.push({
      node_id: c.node_id,
      title: c.title,
      snippet: c.content.slice(0, 120),
    });
  }

  return { text: blocks.join("\n---\n"), nodes };
}
