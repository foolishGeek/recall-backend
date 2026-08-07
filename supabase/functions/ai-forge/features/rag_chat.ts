// Feature: rag_chat. Multi-turn RAG over the user's notes. Policy [D-AI-5]:
// answers are BLENDED — notes-first, enriched with general knowledge.
//
// conversation_id + history window make follow-ups work and give us dialogue
// training data. A cheap question-rewrite step turns "explain the second one"
// into a standalone retrieval query. Failed generations never charge the user.

import { adminClient } from "../../_shared/supabase.ts";
import { resolveScope, shimScopeRequest } from "../../_shared/scope.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { retrieve } from "../../_shared/retrieve.ts";
import { rewriteQuestion } from "../../_shared/question_rewrite.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { assertAllowed, gateCheck, MeterInput, withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireString, asUuidArray } from "../../_shared/validate.ts";
import { RAG_SYSTEM } from "../prompts.ts";

interface HistoryMessage {
  role: string;
  content: string;
}

export async function ragChat(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const question = truncate(stripHtml(requireString(payload.question, "question")), 2000);
  const scoped = shimScopeRequest(payload);
  const requestedBuckets = scoped.bucketIds ?? asUuidArray(payload.bucket_ids);
  const requestedNodes = scoped.nodeIds ?? asUuidArray(payload.node_ids);
  const creditIntent = payload.spend_credit === true ? "spend" : "ask";
  const clientRequestId = typeof payload.client_request_id === "string" ? payload.client_request_id : null;
  let conversationId = typeof payload.conversation_id === "string" ? payload.conversation_id : null;
  const db = adminClient();

  const pre = await gateCheck(userId, "rag_chat");
  assertAllowed(pre);
  const tier = (pre.tier ?? "free") as Tier;

  // Per-user concurrency cap — the ledger makes in-flight count a single query.
  const maxInflight = config.int("ai_max_inflight_per_user", 2);
  const { data: inflight } = await db.rpc("ai_inflight_count", { p_user: userId });
  if ((inflight as number) >= maxInflight) {
    throw new AppError("ai_cooldown", "Another answer is still generating — try again in a moment.");
  }

  conversationId = await ensureConversation(db, userId, conversationId, {
    bucket_ids: requestedBuckets,
    node_ids: requestedNodes,
  });

  const history = await loadHistory(db, conversationId, config);
  const retrievalQuestion = history.length > 0
    ? await rewriteQuestion(config, tier, question, history)
    : question;

  const scope = await resolveScope(db, userId, {
    bucketIds: requestedBuckets,
    nodeIds: requestedNodes,
    assetIds: scoped.assetIds,
    scope: scoped.scope,
  });

  const retrieved = scope.isEmpty
    ? null
    : await retrieve(db, config, {
      feature: "rag_chat",
      userId,
      query: retrievalQuestion,
      bucketIds: scope.bucketIds,
      nodeIds: scope.nodeIds,
    });

  const ctx = retrieved?.context ?? { text: "", nodes: [], used: [] };

  const meter: MeterInput = {
    userId,
    feature: "rag_chat",
    creditIntent,
    clientRequestId,
    conversationId,
  };

  return withMeteredRequest(meter, async (reservation) => {
    const contextText = ctx.text || "(no relevant notes found)";
    const historyBlock = formatHistory(history);
    const userPrompt = [
      `CONTEXT:\n${contextText}`,
      historyBlock ? `CONVERSATION SO FAR:\n${historyBlock}` : "",
      `QUESTION:\n${question}`,
    ].filter(Boolean).join("\n\n");

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
    if (citations.length === 0 && ctx.nodes.length > 0) citations = ctx.nodes;

    await persistTurn(db, conversationId!, question, answer, citations, reservation.requestId);

    const hadNotes = ctx.nodes.length > 0;
    const interactionId = await logInteraction({
      userId,
      feature: "rag_chat",
      scope: {
        kind: scope.kind,
        ids: scope.kind === "nodes"
          ? (scope.nodeIds ?? [])
          : scope.kind === "assets"
          ? (scope.assetIds ?? [])
          : scope.bucketIds,
        bucket_ids: requestedBuckets ?? null,
        node_ids: requestedNodes ?? null,
      },
      retrievedNodeIds: ctx.nodes.map((n) => n.node_id),
      hadNotes,
      blend: hadNotes ? "blended" : "general_only",
      model: gen.model,
      provider: gen.provider,
      latencyMs,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      requestId: reservation.requestId,
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
      scopeKind: scope.kind,
      retrievalMode: retrieved?.mode ?? "none",
      conversationId,
      payload: {
        question,
        retrieval_question: retrievalQuestion,
        context: ctx.text,
        answer,
        history_len: history.length,
      },
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

async function ensureConversation(
  db: ReturnType<typeof adminClient>,
  userId: string,
  conversationId: string | null,
  scope: Record<string, unknown>,
): Promise<string> {
  if (conversationId) {
    const { data } = await db
      .from("ai_conversations")
      .select("id")
      .eq("id", conversationId)
      .eq("user_id", userId)
      .is("archived_at", null)
      .maybeSingle();
    if (data?.id) return data.id as string;
  }
  const { data, error } = await db
    .from("ai_conversations")
    .insert({ user_id: userId, scope })
    .select("id")
    .single();
  if (error) throw error;
  return data.id as string;
}

async function loadHistory(
  db: ReturnType<typeof adminClient>,
  conversationId: string,
  config: AppConfig,
): Promise<HistoryMessage[]> {
  const maxMessages = config.int("ai_chat_history_max_messages", 12);
  const { data } = await db
    .from("ai_messages")
    .select("role, content, token_count")
    .eq("conversation_id", conversationId)
    .in("role", ["user", "assistant", "summary"])
    .order("created_at", { ascending: false })
    .limit(maxMessages);

  const rows = ((data ?? []) as HistoryMessage[]).reverse();
  const maxTokens = config.int("ai_chat_history_max_tokens", 3000);
  let used = 0;
  const kept: HistoryMessage[] = [];
  for (let i = rows.length - 1; i >= 0; i--) {
    const approx = Math.ceil(rows[i].content.length / 4);
    if (used + approx > maxTokens && kept.length > 0) break;
    kept.unshift(rows[i]);
    used += approx;
  }
  return kept;
}

function formatHistory(history: HistoryMessage[]): string {
  return history
    .map((m) => `${m.role === "assistant" ? "Aura" : m.role}: ${m.content}`)
    .join("\n");
}

async function persistTurn(
  db: ReturnType<typeof adminClient>,
  conversationId: string,
  question: string,
  answer: string,
  citations: { node_id: string; title: string; snippet: string }[],
  requestId: string | null,
): Promise<void> {
  await db.from("ai_messages").insert([
    {
      conversation_id: conversationId,
      role: "user",
      content: question,
      token_count: Math.ceil(question.length / 4),
    },
    {
      conversation_id: conversationId,
      role: "assistant",
      content: answer,
      citations,
      request_id: requestId,
      token_count: Math.ceil(answer.length / 4),
    },
  ]);
  await db
    .from("ai_conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
}
