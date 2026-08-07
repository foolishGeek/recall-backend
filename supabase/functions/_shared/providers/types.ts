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
 * that will repeat: a bad API key or a rejected prompt fails the same way
 * everywhere, while a timeout, 429 or 5xx is worth another try elsewhere.
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

/** HTTP statuses worth retrying on a different provider. */
export function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 409 || status === 429 || status >= 500;
}
