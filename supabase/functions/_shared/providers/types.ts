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

export interface GenerateArgs {
  system: string;
  user: string;
  apiKey: string;
  model: string;
  /** Output token budget; quiz generation needs more than short JSON replies. */
  maxTokens?: number;
}
