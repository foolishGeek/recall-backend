// Anthropic provider (premium tier). The Messages API has no JSON mode, so we
// instruct JSON-only in the system prompt and extract the first JSON object.

import { postJson } from "./http.ts";
import { parseEvent, sseLines } from "./sse.ts";
import { GenerateArgs, GenerationResult, StreamChunk } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

const MESSAGES_URL = "https://api.anthropic.com/v1/messages";

const HEADERS = (apiKey: string) => ({
  "x-api-key": apiKey,
  "anthropic-version": "2023-06-01",
});

export async function anthropicGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const json = await postJson({
    provider: "anthropic",
    url: MESSAGES_URL,
    headers: HEADERS(args.apiKey),
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

/** Streams plain prose; the citation trailer carries the structure. */
export async function* anthropicStreamText(args: GenerateArgs): AsyncIterable<StreamChunk> {
  const frames = sseLines({
    provider: "anthropic",
    url: MESSAGES_URL,
    headers: HEADERS(args.apiKey),
    signal: args.signal,
    timeoutMs: args.timeoutMs,
    body: {
      model: args.model,
      max_tokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
      temperature: args.temperature ?? DEFAULT_TEMPERATURE,
      stream: true,
      system: args.system,
      messages: [{ role: "user", content: args.user }],
    },
  });

  // Anthropic splits usage across two events: the prompt count arrives with
  // message_start, the output count only at the end.
  let inputTokens = 0;
  let outputTokens = 0;

  for await (const payload of frames) {
    const frame = parseEvent<{
      type?: string;
      delta?: { text?: string; stop_reason?: string };
      message?: { usage?: { input_tokens?: number; output_tokens?: number } };
      usage?: { input_tokens?: number; output_tokens?: number };
    }>(payload);
    if (!frame) continue;

    switch (frame.type) {
      case "message_start":
        inputTokens = frame.message?.usage?.input_tokens ?? 0;
        outputTokens = frame.message?.usage?.output_tokens ?? 0;
        break;
      case "content_block_delta":
        if (frame.delta?.text) yield { delta: frame.delta.text };
        break;
      case "message_delta":
        outputTokens = frame.usage?.output_tokens ?? outputTokens;
        break;
    }
  }

  yield { delta: "", usage: { input_tokens: inputTokens, output_tokens: outputTokens } };
}
