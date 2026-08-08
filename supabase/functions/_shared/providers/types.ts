// Shared provider contracts. All generative providers return raw JSON text
// (parsed by the caller) plus a normalized token usage count.

export interface Usage {
  input_tokens: number;
  output_tokens: number;
}

export interface GenerationResult {
  /** Raw model text (expected to be JSON for our features). */
  text: string;
  usage: Usage;
}

/** Sampling settings. Defaults come from ai_feature_policy, not from providers. */
export interface Sampling {
  temperature?: number;
  /** Output token budget; quiz generation needs more than short JSON replies. */
  maxTokens?: number;
}

export interface GenerateArgs extends Sampling {
  system: string;
  user: string;
  apiKey: string;
  model: string;
  /** Aborts the request when the caller's deadline passes. */
  signal?: AbortSignal;
  /** Per-call deadline; falls back to the provider default when unset. */
  timeoutMs?: number;
}

/**
 * Streaming contract, declared here so the router and the chat feature agree on
 * the shape before SSE lands (Phase 6). A provider that cannot stream simply
 * does not export one, and the router falls back to the buffered call.
 */
export interface StreamChunk {
  /** Incremental text since the previous chunk. */
  delta: string;
  /** Present only on the final chunk. */
  usage?: Usage;
}

export type GenerateStream = (a: GenerateArgs) => AsyncIterable<StreamChunk>;

/**
 * A provider call that did not produce an answer.
 *
 * `retryable` is what stops us burning a second provider's quota on a mistake
 * that will repeat: a prompt this large is rejected everywhere, while a
 * timeout, a 429 or a retired model says something about who we asked.
 */
export class ProviderError extends Error {
  constructor(
    readonly provider: string,
    readonly status: number | null,
    readonly retryable: boolean,
    message: string,
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

/**
 * Faults in the request itself. Another provider would reject these the same
 * way, so the ladder stops rather than spending a second provider's tokens to
 * reach the same rejection.
 */
const REQUEST_FAULTS = new Set([400, 413, 422]);

/**
 * Whether the same request is worth sending to the next provider.
 *
 * The question is not "was this our fault" but "is this failure about the
 * provider we just asked". A retired model id (404), a key with no access to it
 * (401/403), a rate limit or a 5xx are all specific to that provider, and the
 * next rung of the ladder runs a different model on a different key — which is
 * the entire reason the fallback exists. Treating a 404 as fatal is how one
 * provider retiring one model took the whole feature down.
 */
export function isRetryableStatus(status: number): boolean {
  return !REQUEST_FAULTS.has(status);
}
