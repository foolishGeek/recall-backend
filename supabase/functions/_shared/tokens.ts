// Token counting for the embed pipeline.
//
// Chunk sizes used to be derived from a 4-chars-per-token guess, which is wrong
// in both directions: it overcounts plain English by ~20% and undercounts code
// and accented text by about as much. Undercounting is the dangerous one, since
// text-embedding-3-* rejects inputs over 8191 tokens outright.
//
// The real tokenizer is loaded lazily and only in the embed path, which is
// background work, so its one-off cost never lands on a user-facing request. If
// it cannot load we fall back to the estimate rather than failing the pipeline —
// slightly wrong chunk sizes beat no embeddings at all.

interface Encoder {
  encode(text: string): number[];
}

const CHARS_PER_TOKEN = 4;

let encoder: Encoder | null = null;
let loading: Promise<Encoder | null> | null = null;
let unavailable = false;

/** Rough count, used before the tokenizer is ready and if it never arrives. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

/**
 * Loads the tokenizer for `model` once per isolate. Returns null if it is
 * unavailable, and remembers that so we do not retry on every call.
 */
async function loadEncoder(model: string): Promise<Encoder | null> {
  if (encoder) return encoder;
  if (unavailable) return null;
  if (loading) return loading;

  loading = (async () => {
    try {
      const { encodingForModel } = await import("https://esm.sh/js-tiktoken@1.0.15");
      encoder = encodingForModel(model as Parameters<typeof encodingForModel>[0]);
      return encoder;
    } catch (err) {
      unavailable = true;
      console.error("tokenizer unavailable, estimating token counts:", (err as Error).message);
      return null;
    } finally {
      loading = null;
    }
  })();

  return loading;
}

/** Counts tokens the way `model` does, or estimates if the tokenizer is down. */
export interface TokenCounter {
  count(text: string): number;
  /** False when counts are estimates, so callers can leave token_count unset. */
  exact: boolean;
}

export async function tokenCounter(model: string): Promise<TokenCounter> {
  const enc = await loadEncoder(model);
  if (!enc) return { count: estimateTokens, exact: false };
  return { count: (text: string) => enc.encode(text).length, exact: true };
}
