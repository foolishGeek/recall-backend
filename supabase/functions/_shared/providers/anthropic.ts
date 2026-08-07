// Anthropic provider (premium tier). The Messages API has no JSON mode, so we
// instruct JSON-only in the system prompt and extract the first JSON object.

import { postJson } from "./http.ts";
import { GenerateArgs, GenerationResult } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

export async function anthropicGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const json = await postJson({
    provider: "anthropic",
    url: "https://api.anthropic.com/v1/messages",
    headers: {
      "x-api-key": args.apiKey,
      "anthropic-version": "2023-06-01",
    },
    signal: args.signal,
    timeoutMs: args.timeoutMs,
    body: {
      model: args.model,
      max_tokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
      temperature: args.temperature ?? DEFAULT_TEMPERATURE,
      system: `${args.system}\nRespond with valid JSON only. No prose, no code fences.`,
      messages: [{ role: "user", content: args.user }],
    },
  }) as {
    content?: { type: string; text?: string }[];
    usage?: { input_tokens?: number; output_tokens?: number };
  };

  const text = (json?.content ?? [])
    .filter((b) => b.type === "text")
    .map((b) => b.text ?? "")
    .join("");

  return {
    text,
    usage: {
      input_tokens: json?.usage?.input_tokens ?? 0,
      output_tokens: json?.usage?.output_tokens ?? 0,
    },
  };
}
