// Anthropic provider (premium tier). The Messages API has no JSON mode, so we
// instruct JSON-only in the system prompt and extract the first JSON object.

import { AppError } from "../errors.ts";
import { GenerateArgs, GenerationResult } from "./types.ts";

export async function anthropicGenerateJson(args: GenerateArgs): Promise<GenerationResult> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": args.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: args.model,
      max_tokens: 1024,
      temperature: 0.2,
      system: `${args.system}\nRespond with valid JSON only. No prose, no code fences.`,
      messages: [{ role: "user", content: args.user }],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new AppError("provider_error", `Anthropic ${res.status}: ${body.slice(0, 200)}`);
  }

  const json = await res.json();
  const text = (json?.content ?? [])
    .filter((b: { type: string }) => b.type === "text")
    .map((b: { text: string }) => b.text)
    .join("");
  return {
    text,
    usage: {
      input_tokens: json?.usage?.input_tokens ?? 0,
      output_tokens: json?.usage?.output_tokens ?? 0,
    },
  };
}
