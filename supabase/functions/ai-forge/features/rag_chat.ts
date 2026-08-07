// Feature: rag_chat. Retrieve owned chunks within the active-bucket scope,
// then answer with citations. Policy [D-AI-5]: answers are BLENDED —
// notes-first, enriched with general knowledge. An empty corpus still calls
// the model (general knowledge) and counts as one AI request.

import { adminClient } from "../../_shared/supabase.ts";
import { resolveScope } from "../../_shared/scope.ts";
import { AppConfig } from "../../_shared/config.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { retrieve } from "../../_shared/retrieve.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { assertAllowed, gateCheck, MeterInput, withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireString, asUuidArray } from "../../_shared/validate.ts";
import { RAG_SYSTEM } from "../prompts.ts";

export async function ragChat(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const question = truncate(stripHtml(requireString(payload.question, "question")), 2000);
  const requestedBuckets = asUuidArray(payload.bucket_ids);
  const requestedNodes = asUuidArray(payload.node_ids);
  // Chat never auto-spends a credit during cooldown: the first call ASKS (429
  // ai_cooldown -> interstitial); an explicit "Continue with 1 credit" retry
  // sends spend_credit:true so the gate deducts a credit (or 403) [D-AI-1].
  const creditIntent = payload.spend_credit === true ? "spend" : "ask";
  // Optional idempotency key: a client retry after a timeout replays the stored
  // answer instead of paying for a second generation.
  const clientRequestId = typeof payload.client_request_id === "string" ? payload.client_request_id : null;
  const db = adminClient();

  // Entitlement / maintenance pre-flight before any retrieval work.
  const pre = await gateCheck(userId, "rag_chat");
  assertAllowed(pre);
  const tier = (pre.tier ?? "free") as Tier;

  // Resolve the scope server-side [AI-PROMPTS § Active bucket scope].
  const scope = await resolveScope(db, userId, {
    bucketIds: requestedBuckets,
    nodeIds: requestedNodes,
  });

  const retrieved = scope.isEmpty
    ? null
    : await retrieve(db, config, {
      feature: "rag_chat",
      userId,
      query: question,
      bucketIds: scope.bucketIds,
      nodeIds: scope.nodeIds,
    });

  const ctx = retrieved?.context ?? { text: "", nodes: [], used: [] };

  // Blended policy: always answer (notes-first, general knowledge fills gaps).
  // Even an empty corpus calls the model and counts as one AI request.
  // Retrieval above is free. Only the generation is metered, and the hold is
  // released if the provider throws — a failed chat costs the user nothing.
  const meter: MeterInput = { userId, feature: "rag_chat", creditIntent, clientRequestId };
  return withMeteredRequest(meter, async (reservation) => {
    const contextText = ctx.text || "(no relevant notes found)";
    const userPrompt = `CONTEXT:\n${contextText}\n\nQUESTION:\n${question}`;
    const system = RAG_SYSTEM + (await userDirectives(userId));
    const t0 = Date.now();
    const gen = await generateJson(config, tier, system, userPrompt, {
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
    });
    const latencyMs = Date.now() - t0;

    const answer = typeof gen.json.answer === "string" ? gen.json.answer : "";
    const cited = Array.isArray(gen.json.cited_node_ids) ? (gen.json.cited_node_ids as string[]) : [];
    const byId = new Map(ctx.nodes.map((n) => [n.node_id, n]));
    let citations = cited
      .map((id) => byId.get(id))
      .filter((n): n is { node_id: string; title: string; snippet: string } => !!n);
    // If the model used notes but omitted ids, surface what we retrieved. When we
    // had no notes at all, leave citations empty (general-knowledge answer).
    if (citations.length === 0 && ctx.nodes.length > 0) citations = ctx.nodes;

    const hadNotes = ctx.nodes.length > 0;
    const interactionId = await logInteraction({
      userId,
      feature: "rag_chat",
      scope: { bucket_ids: requestedBuckets ?? null, node_ids: requestedNodes ?? null },
      retrievedNodeIds: ctx.nodes.map((n) => n.node_id),
      hadNotes,
      blend: hadNotes ? "blended" : "general_only",
      model: gen.model,
      latencyMs,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      payload: { question, context: ctx.text, answer },
    });
    return {
      result: { answer, citations, model: gen.model, usage: gen.usage, interaction_id: interactionId },
      model: gen.model,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      cacheResponse: true,
    };
  });
}
