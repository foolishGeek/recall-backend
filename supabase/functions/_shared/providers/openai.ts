// OpenAI provider: JSON chat completions (GPT-4o-mini fallback) + embeddings
// (text-embedding-3-small, 1536 dims to match node_chunks.embedding).

import { AppError } from "../errors.ts";
import { GenerateArgs, GenerationResult } from "./types.ts";

export async function openaiGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${args.apiKey}`,
    },
    body: JSON.stringify({
      model: args.model,
      temperature: 0.2,
      max_tokens: args.maxTokens ?? 2048,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: args.system },
        { role: "user", content: args.user },
      ],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new AppError("provider_error", `OpenAI ${res.status}: ${body.slice(0, 200)}`);
  }

  const json = await res.json();
  const text = json?.choices?.[0]?.message?.content ?? "";
  return {
    text,
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
): Promise<{ embeddings: number[][]; inputTokens: number }> {
  const res = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ model, input: inputs }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new AppError("provider_error", `OpenAI embed ${res.status}: ${body.slice(0, 200)}`);
  }

  const json = await res.json();
  const embeddings: number[][] = (json?.data ?? [])
    .sort((a: { index: number }, b: { index: number }) => a.index - b.index)
    .map((d: { embedding: number[] }) => d.embedding);
  return { embeddings, inputTokens: json?.usage?.prompt_tokens ?? 0 };
}
