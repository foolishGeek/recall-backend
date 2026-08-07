// Cheap follow-up rewrite: turn "explain the second one" into a standalone
// question so retrieval still works. Captured as its own task for later LoRA.

import { AppConfig } from "./config.ts";
import { generateJson, Tier } from "./providers/route.ts";

const SYSTEM = `You rewrite a follow-up chat message into one self-contained question.
Rules:
- Preserve the user's intent and any proper nouns.
- Use the recent conversation for context; do not invent facts.
- Return only the rewritten question, no preamble.
Output JSON only: { "question": "…" }`;

export async function rewriteQuestion(
  config: AppConfig,
  tier: Tier,
  followUp: string,
  history: { role: string; content: string }[],
  sampling?: { temperature?: number; maxTokens?: number },
): Promise<string> {
  if (history.length === 0) return followUp;
  const prior = history
    .slice(-6)
    .map((m) => `${m.role}: ${m.content}`)
    .join("\n");
  try {
    const gen = await generateJson(
      config,
      tier,
      SYSTEM,
      `CONVERSATION:\n${prior}\n\nFOLLOW-UP:\n${followUp}`,
      {
        temperature: sampling?.temperature ?? 0,
        maxTokens: sampling?.maxTokens ?? 128,
      },
    );
    const q = typeof gen.json.question === "string" ? gen.json.question.trim() : "";
    return q || followUp;
  } catch {
    return followUp;
  }
}
