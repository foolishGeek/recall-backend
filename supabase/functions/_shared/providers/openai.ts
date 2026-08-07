// OpenAI provider: JSON chat completions (GPT-4o-mini fallback) + embeddings
// (text-embedding-3-small, 1536 dims to match node_chunks.embedding).

import { postJson } from "./http.ts";
import { GenerateArgs, GenerationResult, ProviderError } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

export async function openaiGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const json = await postJson({
    provider: "openai",
    url: "https://api.openai.com/v1/chat/completions",
    headers: { Authorization: `Bearer ${args.apiKey}` },
    signal: args.signal,
    timeoutMs: args.timeoutMs,
    body: {
      model: args.model,
      temperature: args.temperature ?? DEFAULT_TEMPERATURE,
      max_tokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: args.system },
        { role: "user", content: args.user },
      ],
    },
  }) as {
    choices?: { message?: { content?: string } }[];
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };

  return {
    text: json?.choices?.[0]?.message?.content ?? "",
    usage: {
      input_tokens: json?.usage?.prompt_tokens ?? 0,
      output_tokens: json?.usage?.completion_tokens ?? 0,
    },
  };
}

export async function openaiEmbed(
  apiKey: string,
  model: string,
  inputs: string[],
  signal?: AbortSignal,
): Promise<{ embeddings: number[][]; inputTokens: number }> {
  const json = await postJson({
    provider: "openai-embed",
    url: "https://api.openai.com/v1/embeddings",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: { model, input: inputs },
    signal,
  }) as {
    data?: { index: number; embedding: number[] }[];
    usage?: { prompt_tokens?: number };
  };

  const embeddings = (json?.data ?? [])
    .slice()
    .sort((a, b) => a.index - b.index)
    .map((d) => d.embedding);

  // A short batch would silently misalign chunks with their vectors.
  if (embeddings.length !== inputs.length) {
    throw new ProviderError(
      "openai-embed",
      null,
      true,
      `expected ${inputs.length} embeddings, got ${embeddings.length}`,
    );
  }

  return { embeddings, inputTokens: json?.usage?.prompt_tokens ?? 0 };
}
