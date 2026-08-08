// Google Gemini provider (free tier). Uses generateContent with a JSON response
// mime type so the model returns parseable JSON, and streamGenerateContent for
// chat, where the answer is prose the user watches arrive.

import { postJson } from "./http.ts";
import { parseEvent, sseLines } from "./sse.ts";
import { GenerateArgs, GenerationResult, StreamChunk } from "./types.ts";

const DEFAULT_TEMPERATURE = 0.2;
const DEFAULT_MAX_TOKENS = 2048;

const HOST = "https://generativelanguage.googleapis.com/v1beta/models";

interface GeminiFrame {
  candidates?: { content?: { parts?: { text?: string }[] } }[];
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
}

export async function geminiGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const json = await postJson({
    provider: "gemini",
    url: `${HOST}/${args.model}:generateContent?key=${args.apiKey}`,
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
  }) as GeminiFrame;

  const text = frameText(json);

  return {
    text,
    usage: {
      input_tokens: json?.usageMetadata?.promptTokenCount ?? 0,
      output_tokens: json?.usageMetadata?.candidatesTokenCount ?? 0,
    },
  };
}

/** Streams plain prose. No responseMimeType — JSON mode and streaming to a
 * reader are opposite goals; the citation trailer carries the structure. */
export async function* geminiStreamText(args: GenerateArgs): AsyncIterable<StreamChunk> {
  const frames = sseLines({
    provider: "gemini",
    url: `${HOST}/${args.model}:streamGenerateContent?alt=sse&key=${args.apiKey}`,
    headers: {},
    signal: args.signal,
    timeoutMs: args.timeoutMs,
    body: {
      systemInstruction: { parts: [{ text: args.system }] },
      contents: [{ role: "user", parts: [{ text: args.user }] }],
      generationConfig: {
        temperature: args.temperature ?? DEFAULT_TEMPERATURE,
        maxOutputTokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
      },
    },
  });

  // Gemini repeats cumulative usage on every frame, so the last one wins rather
  // than the numbers being summed.
  let usage: StreamChunk["usage"];
  for await (const payload of frames) {
    const frame = parseEvent<GeminiFrame>(payload);
    if (!frame) continue;
    if (frame.usageMetadata) {
      usage = {
        input_tokens: frame.usageMetadata.promptTokenCount ?? 0,
        output_tokens: frame.usageMetadata.candidatesTokenCount ?? 0,
      };
    }
    const delta = frameText(frame);
    if (delta) yield { delta };
  }

  yield { delta: "", usage: usage ?? { input_tokens: 0, output_tokens: 0 } };
}

function frameText(frame: GeminiFrame | null): string {
  return (frame?.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? "").join("");
}
