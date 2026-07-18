// Google Gemini provider (free tier). Uses generateContent with a JSON response
// mime type so the model returns parseable JSON.

import { AppError } from "../errors.ts";
import { GenerateArgs, GenerationResult } from "./types.ts";

export async function geminiGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${args.model}:generateContent?key=${args.apiKey}`;

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: args.system }] },
      contents: [{ role: "user", parts: [{ text: args.user }] }],
      generationConfig: {
        temperature: 0.2,
        maxOutputTokens: args.maxTokens ?? 2048,
        responseMimeType: "application/json",
      },
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new AppError("provider_error", `Gemini ${res.status}: ${body.slice(0, 200)}`);
  }

  const json = await res.json();
  const text = (json?.candidates?.[0]?.content?.parts ?? [])
    .map((p: { text?: string }) => p.text ?? "")
    .join("");
  return {
    text,
    usage: {
      input_tokens: json?.usageMetadata?.promptTokenCount ?? 0,
      output_tokens: json?.usageMetadata?.candidatesTokenCount ?? 0,
    },
  };
}
