// OpenAI provider: JSON chat completions (GPT-4o-mini fallback) + embeddings
// (text-embedding-3-small, 1536 dims to match node_chunks.embedding).

import { postJson } from "./http.ts";
import { parseEvent, sseLines } from "./sse.ts";
import { GenerateArgs, GenerationResult, ProviderError, StreamChunk } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

const CHAT_URL = "https://api.openai.com/v1/chat/completions";

export async function openaiGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const json = await postJson({
    provider: "openai",
    url: CHAT_URL,
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

/** Streams plain prose; the citation trailer carries the structure. */
export function openaiStreamText(args: GenerateArgs): AsyncIterable<StreamChunk> {
  return openAiCompatibleStream("openai", CHAT_URL, args);
}

/**
 * The chat-completions SSE dialect, shared with any OpenAI-compatible endpoint
 * (vLLM, TGI). Only the URL and the provider label differ, and a second copy of
 * this parser is a second place for the usage block to go missing.
 */
export async function* openAiCompatibleStream(
  provider: string,
  url: string,
  args: GenerateArgs,
): AsyncIterable<StreamChunk> {
  const frames = sseLines({
    provider,
    url,
    headers: { Authorization: `Bearer ${args.apiKey}` },
    signal: args.signal,
    timeoutMs: args.timeoutMs,
    body: {
      model: args.model,
      temperature: args.temperature ?? DEFAULT_TEMPERATURE,
      max_tokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
      stream: true,
      // Without this the usage block never arrives and the ledger records a
      // request that cost nothing.
      stream_options: { include_usage: true },
      messages: [
        { role: "system", content: args.system },
        { role: "user", content: args.user },
      ],
    },
  });

  let usage: StreamChunk["usage"];
  for await (const payload of frames) {
    const frame = parseEvent<{
      choices?: { delta?: { content?: string } }[];
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    }>(payload);
    if (!frame) continue;
    if (frame.usage) {
      usage = {
        input_tokens: frame.usage.prompt_tokens ?? 0,
        output_tokens: frame.usage.completion_tokens ?? 0,
      };
    }
    const delta = frame.choices?.[0]?.delta?.content ?? "";
    if (delta) yield { delta };
  }

  yield { delta: "", usage: usage ?? { input_tokens: 0, output_tokens: 0 } };
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
