// Token-approximate chunker for the embed pipeline. We size in characters using
// a ~4 chars/token heuristic so chunk_size_tokens / overlap_tokens from
// app_config map to character windows without a tokenizer dependency.

const CHARS_PER_TOKEN = 4;

export function chunkText(
  text: string,
  sizeTokens: number,
  overlapTokens: number,
): string[] {
  const clean = text.replace(/\s+/g, " ").trim();
  if (!clean) return [];

  const size = Math.max(1, sizeTokens * CHARS_PER_TOKEN);
  const overlap = Math.max(0, Math.min(overlapTokens * CHARS_PER_TOKEN, size - 1));
  const step = size - overlap;

  const chunks: string[] = [];
  for (let start = 0; start < clean.length; start += step) {
    const piece = clean.slice(start, start + size).trim();
    if (piece) chunks.push(piece);
    if (start + size >= clean.length) break;
  }
  return chunks;
}
