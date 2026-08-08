// Feature: rag_chat — buffered answer. Policy [D-AI-5]: answers are BLENDED,
// notes-first and enriched with general knowledge.
//
// The pipeline around the model call lives in chat_core.ts, shared with the
// streaming path. What is left here is the one thing that differs: a single
// JSON reply carrying the answer and its citations together.

import { AppConfig } from "../../_shared/config.ts";
import { registerPrompt } from "../../_shared/prompt_registry.ts";
import { generateJson } from "../../_shared/providers/route.ts";
import { withMeteredRequest } from "../../_shared/quota.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { RAG_SYSTEM } from "../prompts.ts";
import { buildUserPrompt, finishTurn, prepareChat, resolveCitations } from "./chat_core.ts";

export async function ragChat(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const prepared = await prepareChat(payload, userId, config);
  const prompt = await registerPrompt("rag_chat", RAG_SYSTEM);

  return withMeteredRequest(prepared.meter, async (reservation) => {
    const userPrompt = buildUserPrompt(prepared);
    const system = RAG_SYSTEM + (await userDirectives(userId));

    const t0 = Date.now();
    const gen = await generateJson(config, prepared.tier, system, userPrompt, {
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
    });
    const latencyMs = Date.now() - t0;

    const answer = typeof gen.json.answer === "string" ? gen.json.answer : "";
    const cited = Array.isArray(gen.json.cited_node_ids)
      ? (gen.json.cited_node_ids as string[])
      : [];
    const citations = resolveCitations(prepared.ctx, cited);

    const { interactionId, conversationId } = await finishTurn(prepared, reservation, {
      answer,
      citations,
      model: gen.model,
      provider: gen.provider,
      usage: gen.usage,
      latencyMs,
      promptId: prompt.promptId,
      systemPromptSha: prompt.sha,
    });

    return {
      result: {
        answer,
        citations,
        model: gen.model,
        usage: gen.usage,
        interaction_id: interactionId,
        conversation_id: conversationId,
      },
      model: gen.model,
      provider: gen.provider,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      cacheResponse: true,
    };
  });
}
