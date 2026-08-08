// OpenAI-compatible client against AI_SELFHOST_URL (vLLM, TGI, etc.).
// Optional; only registered in route.ts when the env var is set.

import { postJson } from "./http.ts";
import { openAiCompatibleStream } from "./openai.ts";
import { GenerateArgs, GenerationResult, StreamChunk } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

function baseUrl(): string {
  return (Deno.env.get("AI_SELFHOST_URL") ?? "").replace(/\/$/, "");
}

export function selfhostConfigured(): boolean {
  return baseUrl().length > 0;
}

function key(args: GenerateArgs): string {
  return args.apiKey || Deno.env.get("AI_SELFHOST_API_KEY") || "not-needed";
}

/** Our own model, streaming the same dialect it already serves for buffered calls. */
export function selfhostStreamText(args: GenerateArgs): AsyncIterable<StreamChunk> {
  return openAiCompatibleStream("selfhost", `${baseUrl()}/v1/chat/completions`, {
    ...args,
    apiKey: key(args),
  });
}

export async function selfhostGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const root = baseUrl();
  const apiKey = key(args);

  const json = await postJson({
    provider: "selfhost",
    url: `${root}/v1/chat/completions`,
    headers: { Authorization: `Bearer ${apiKey}` },
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
