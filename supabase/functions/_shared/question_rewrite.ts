// Cheap follow-up rewrite: turn "explain the second one" into a standalone
// question so retrieval still works.
//
// Unmetered — the user asked one question, not two, so this is our cost. It is
// still captured as its own task, because "rewrite a follow-up" is one of the
// easiest adapters to train and needs paired examples from day one.

import { AppConfig } from "./config.ts";
import { generateJson, Tier } from "./providers/route.ts";
import { logInteraction } from "./interactions.ts";
import { registerPrompt } from "./prompt_registry.ts";

const SYSTEM = `You rewrite a follow-up chat message into one self-contained question.
Rules:
- Preserve the user's intent and any proper nouns.
- Use the recent conversation for context; do not invent facts.
- Return only the rewritten question, no preamble.
Output JSON only: { "question": "…" }`;

export interface RewriteContext {
  userId?: string;
  conversationId?: string | null;
}

export async function rewriteQuestion(
  config: AppConfig,
  tier: Tier,
  followUp: string,
  history: { role: string; content: string }[],
  ctx: RewriteContext = {},
  sampling?: { temperature?: number; maxTokens?: number },
): Promise<string> {
  if (history.length === 0) return followUp;
  const prior = history
    .slice(-6)
    .map((m) => `${m.role}: ${m.content}`)
    .join("\n");
  const input = `CONVERSATION:\n${prior}\n\nFOLLOW-UP:\n${followUp}`;

  try {
    const t0 = Date.now();
    const gen = await generateJson(config, tier, SYSTEM, input, {
      temperature: sampling?.temperature ?? 0,
      maxTokens: sampling?.maxTokens ?? 128,
    });
    const q = typeof gen.json.question === "string" ? gen.json.question.trim() : "";

    if (ctx.userId) {
      const prompt = await registerPrompt("question_rewrite", SYSTEM);
      await logInteraction({
        userId: ctx.userId,
        feature: "question_rewrite",
        model: gen.model,
        provider: gen.provider,
        latencyMs: Date.now() - t0,
        inputTokens: gen.usage.input_tokens,
        outputTokens: gen.usage.output_tokens,
        conversationId: ctx.conversationId ?? null,
        promptId: prompt.promptId,
        systemPromptSha: prompt.sha,
        payload: { follow_up: followUp, history: prior, rewritten: q || followUp },
      });
    }

    return q || followUp;
  } catch {
    return followUp;
  }
}
