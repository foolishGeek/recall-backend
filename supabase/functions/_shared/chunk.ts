// Structure-aware chunker for the embed pipeline.
//
// The previous version collapsed all whitespace and then cut every N characters.
// That destroyed the two things retrieval leans on hardest: it flattened
// headings, lists and code into one run-on line, and it sliced mid-sentence, so
// a chunk often began and ended mid-thought and matched nothing well.
//
// This walks the document's own structure instead -- headings, paragraphs, list
// runs and fenced code are the units -- and packs whole units up to the target
// size, only falling back to sentence and then word splitting for a unit that is
// too big on its own. A heading starts a new chunk and leads it, so the chunk
// carries the context of the section it came from.

export interface Chunk {
  content: string;
  /** Tokens in `content` alone; the embed step adds the context header. */
  tokens: number;
  /** Nearest preceding heading, or null. Kept for citations and future rerank. */
  heading: string | null;
}

export interface ChunkOptions {
  sizeTokens: number;
  overlapTokens: number;
  /** Chunks smaller than this are folded into their neighbour. */
  minTokens: number;
  /** Budget the embed step will spend on the context header. */
  reserveTokens?: number;
  count: (text: string) => number;
}

type BlockKind = "heading" | "code" | "list" | "para";

interface Block {
  text: string;
  kind: BlockKind;
  heading: string | null;
}

const HEADING = /^#{1,6}\s+\S/;
const FENCE = /^\s*(```|~~~)/;
const LIST_ITEM = /^\s*([-*+]|\d+[.)])\s+\S/;

/** Splits the document into the units we refuse to cut through. */
function parseBlocks(text: string): Block[] {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const blocks: Block[] = [];
  let heading: string | null = null;
  let buffer: string[] = [];
  let bufferKind: BlockKind = "para";

  const flush = () => {
    const body = buffer.join("\n").trim();
    if (body) blocks.push({ text: body, kind: bufferKind, heading });
    buffer = [];
    bufferKind = "para";
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // A fenced block is opaque: splitting code mid-function helps nobody.
    if (FENCE.test(line)) {
      flush();
      const fence = line.trim().slice(0, 3);
      const fenced = [line];
      for (i++; i < lines.length; i++) {
        fenced.push(lines[i]);
        if (lines[i].trim().startsWith(fence)) break;
      }
      blocks.push({ text: fenced.join("\n"), kind: "code", heading });
      continue;
    }

    if (HEADING.test(line)) {
      flush();
      heading = line.replace(/^#+\s+/, "").trim();
      blocks.push({ text: line.trim(), kind: "heading", heading });
      continue;
    }

    if (!line.trim()) {
      flush();
      continue;
    }

    // Consecutive list items belong together; a lone bullet is not a thought.
    const kind: BlockKind = LIST_ITEM.test(line) ? "list" : "para";
    if (buffer.length && kind !== bufferKind) flush();
    bufferKind = kind;
    buffer.push(line);
  }

  flush();
  return blocks;
}

function splitSentences(text: string): string[] {
  const parts = text
    .split(/(?<=[.!?;:])\s+|\n+/)
    .map((s) => s.trim())
    .filter(Boolean);
  return parts.length ? parts : [text.trim()];
}

/** Last resort for a single sentence that still exceeds the budget. */
function splitWords(text: string, budget: number, count: (t: string) => number): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  const out: string[] = [];
  let current: string[] = [];

  for (const word of words) {
    if (current.length && count([...current, word].join(" ")) > budget) {
      out.push(current.join(" "));
      current = [word];
    } else {
      current.push(word);
    }
  }
  if (current.length) out.push(current.join(" "));
  return out;
}

/**
 * Breaks one oversized block into pieces that each fit the budget. A code block
 * bigger than a whole chunk cannot be kept intact, so it is split on lines —
 * arbitrary, but far better than breaking on punctuation inside an expression.
 */
function splitBlock(block: Block, budget: number, count: (t: string) => number): string[] {
  const isCode = block.kind === "code";
  const units = isCode
    ? block.text.split("\n").filter((l) => l.length > 0)
    : splitSentences(block.text);
  const join = isCode ? "\n" : " ";

  const pieces: string[] = [];
  let current: string[] = [];

  const flush = () => {
    if (current.length) pieces.push(current.join(join));
    current = [];
  };

  for (const unit of units) {
    if (count(unit) > budget) {
      flush();
      pieces.push(...splitWords(unit, budget, count));
      continue;
    }
    if (current.length && count([...current, unit].join(join)) > budget) {
      flush();
      current = [unit];
    } else {
      current.push(unit);
    }
  }

  flush();
  return pieces.filter(Boolean);
}

/** Trailing sentences of `text` totalling at most `budget` tokens. */
function tailOverlap(text: string, budget: number, count: (t: string) => number): string {
  if (budget <= 0) return "";
  const sentences = splitSentences(text);
  const kept: string[] = [];

  for (let i = sentences.length - 1; i >= 0; i--) {
    const candidate = [sentences[i], ...kept].join(" ");
    if (count(candidate) > budget) break;
    kept.unshift(sentences[i]);
  }
  return kept.join(" ");
}

export function chunkDocument(text: string, opts: ChunkOptions): Chunk[] {
  // What one stored chunk may total, once the embed step's header is paid for.
  const budget = Math.max(32, opts.sizeTokens - (opts.reserveTokens ?? 0));
  const overlap = Math.max(0, Math.min(opts.overlapTokens, Math.floor(budget / 3)));
  // The overlap is a prefix, so new content only gets what is left. Sizing
  // content to the full budget is what previously squeezed the overlap out.
  const contentBudget = Math.max(24, budget - overlap);
  const count = opts.count;

  const blocks = parseBlocks(text.trim());
  if (blocks.length === 0) return [];

  const chunks: Chunk[] = [];
  let carried = "";           // tail of the previous chunk, at most `overlap`
  let parts: string[] = [];   // new content, at most `contentBudget`
  let heading: string | null = null;

  const flush = () => {
    const body = [carried, ...parts].filter(Boolean).join("\n\n").trim();
    if (body) chunks.push({ content: body, tokens: count(body), heading });
    carried = "";
    parts = [];
  };

  // Opens the next chunk with the tail of the one just closed, so a thought that
  // straddles the boundary is still findable from either side.
  const closeAndCarry = () => {
    flush();
    const previous = chunks[chunks.length - 1];
    carried = previous ? tailOverlap(previous.content, overlap, count) : "";
  };

  for (const block of blocks) {
    // A heading introduces a section, so it leads a chunk rather than trailing
    // one, and it needs no overlap in front of it.
    if (block.kind === "heading") {
      flush();
      parts = [block.text];
      heading = block.heading;
      continue;
    }

    heading = block.heading;
    const pieces = count(block.text) > contentBudget
      ? splitBlock(block, contentBudget, count)
      : [block.text];

    for (const piece of pieces) {
      if (parts.length && count([...parts, piece].join("\n\n")) > contentBudget) {
        closeAndCarry();
      }
      parts.push(piece);
    }
  }
  flush();

  return mergeRunts(chunks, opts.minTokens, budget, count);
}

/**
 * Folds undersized chunks into a neighbour. A 12-token fragment embeds to a
 * vector that matches almost any query weakly and nothing strongly, so it only
 * adds noise to retrieval.
 */
function mergeRunts(
  chunks: Chunk[],
  minTokens: number,
  budget: number,
  count: (t: string) => number,
): Chunk[] {
  if (chunks.length < 2) return chunks;
  const out: Chunk[] = [];

  for (const chunk of chunks) {
    const previous = out[out.length - 1];
    const tooSmall = chunk.tokens < minTokens;
    if (previous && tooSmall) {
      const merged = `${previous.content}\n\n${chunk.content}`;
      const tokens = count(merged);
      if (tokens <= budget) {
        out[out.length - 1] = { content: merged, tokens, heading: previous.heading };
        continue;
      }
    }
    out.push(chunk);
  }

  // A single leading runt has no previous chunk to join, so fold it forward.
  if (out.length > 1 && out[0].tokens < minTokens) {
    const merged = `${out[0].content}\n\n${out[1].content}`;
    const tokens = count(merged);
    if (tokens <= budget) {
      out.splice(0, 2, { content: merged, tokens, heading: out[0].heading });
    }
  }

  return out;
}
