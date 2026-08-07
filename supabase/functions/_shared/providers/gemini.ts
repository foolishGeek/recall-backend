// Google Gemini provider (free tier). Uses generateContent with a JSON response
// mime type so the model returns parseable JSON.

import { postJson } from "./http.ts";
import { GenerateArgs, GenerationResult } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

export async function geminiGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const json = await postJson({
    provider: "gemini",
    url:
      `https://generativelanguage.googleapis.com/v1beta/models/${args.model}:generateContent?key=${args.apiKey}`,
    headers: {},
    signal: args.signal,
    timeoutMs: args.timeoutMs,
    body: {
      systemInstruction: { parts: [{ text: args.system }] },
      contents: [{ role: "user", parts: [{ text: args.user }] }],
      generationConfig: {
        temperature: args.temperature ?? DEFAULT_TEMPERATURE,
        maxOutputTokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
        responseMimeType: "application/json",
      },
    },
  }) as {
    candidates?: { content?: { parts?: { text?: string }[] } }[];
    usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
  };

  const text = (json?.candidates?.[0]?.content?.parts ?? [])
    .map((p) => p.text ?? "")
    .join("");

  return {
    text,
    usage: {
      input_tokens: json?.usageMetadata?.promptTokenCount ?? 0,
      output_tokens: json?.usageMetadata?.candidatesTokenCount ?? 0,
    },
  };
}
