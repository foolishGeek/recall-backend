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
import { captureRetrieval } from "../../_shared/retrieval_capture.ts";
import { rewriteQuestion } from "../../_shared/question_rewrite.ts";
import { registerPrompt } from "../../_shared/prompt_registry.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { assertAllowed, gateCheck, MeterInput, withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireString, asUuidArray } from "../../_shared/validate.ts";
import { CHAT_SUMMARY_SYSTEM, RAG_SYSTEM } from "../prompts.ts";

type Db = ReturnType<typeof adminClient>;

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
  const replacesInteractionId = typeof payload.replaces_interaction_id === "string"
    ? payload.replaces_interaction_id
    : null;
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

  // Only an existing, owned thread counts. A new thread is not written until
  // there is an answer to put in it, so a denied or failed send cannot leave an
  // empty conversation behind.
  conversationId = await resolveConversation(db, userId, conversationId);

  // Regenerate: the answer the user rejected must leave the thread before the
  // retry reads it back as history, or the second attempt is a continuation of
  // the answer it was meant to replace.
  if (conversationId && replacesInteractionId) {
    await dropSupersededTurn(db, userId, conversationId, replacesInteractionId);
  }

  const history = conversationId
    ? await boundedHistory(db, config, tier, userId, conversationId)
    : [];
  const retrievalQuestion = history.length > 0
    ? await rewriteQuestion(config, tier, question, history, { userId, conversationId })
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
      assetIds: scope.assetIds,
      sourceKinds: scope.kind === "assets" ? ["asset"] : null,
    });

  const ctx = retrieved?.context ?? { text: "", nodes: [], used: [] };
  const prompt = await registerPrompt("rag_chat", RAG_SYSTEM);

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

    conversationId ??= await createConversation(db, userId, {
      bucket_ids: requestedBuckets,
      node_ids: requestedNodes,
    });
    await persistTurn(db, conversationId, question, answer, citations, reservation.requestId);

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
      promptId: prompt.promptId,
      systemPromptSha: prompt.sha,
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

    await captureRetrieval(interactionId, retrieved);
    // A regenerate is a preference pair for free: this answer beat that one.
    if (interactionId && replacesInteractionId) {
      await recordRegenerate(db, userId, interactionId, replacesInteractionId);
    }

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

/** The caller's thread if it exists and is theirs; otherwise null. */
async function resolveConversation(
  db: Db,
  userId: string,
  conversationId: string | null,
): Promise<string | null> {
  if (!conversationId) return null;
  const { data } = await db
    .from("ai_conversations")
    .select("id")
    .eq("id", conversationId)
    .eq("user_id", userId)
    .is("archived_at", null)
    .maybeSingle();
  return (data?.id as string | undefined) ?? null;
}

async function createConversation(
  db: Db,
  userId: string,
  scope: Record<string, unknown>,
): Promise<string> {
  const { data, error } = await db
    .from("ai_conversations")
    .insert({ user_id: userId, scope })
    .select("id")
    .single();
  if (error) throw error;
  return data.id as string;
}

/**
 * Remove the rejected question/answer pair from the thread. Keyed on the
 * replaced interaction's ledger id so it can only ever drop the turn the client
 * actually discarded. Best-effort: failing to tidy up must not block the retry.
 */
async function dropSupersededTurn(
  db: Db,
  userId: string,
  conversationId: string,
  replacedInteractionId: string,
): Promise<void> {
  try {
    const { data: prior } = await db
      .from("ai_interactions")
      .select("request_id")
      .eq("id", replacedInteractionId)
      .eq("user_id", userId)
      .maybeSingle();
    const requestId = (prior as { request_id: string | null } | null)?.request_id;
    if (!requestId) return;

    const { data: assistant } = await db
      .from("ai_messages")
      .select("id, created_at")
      .eq("conversation_id", conversationId)
      .eq("request_id", requestId)
      .maybeSingle();
    const row = assistant as { id: string; created_at: string } | null;
    if (!row) return;

    const { data: asked } = await db
      .from("ai_messages")
      .select("id")
      .eq("conversation_id", conversationId)
      .eq("role", "user")
      .lt("created_at", row.created_at)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const ids = [row.id, (asked as { id: string } | null)?.id].filter(Boolean) as string[];
    await db.from("ai_messages").delete().in("id", ids);
  } catch (e) {
    console.error("dropSupersededTurn failed:", (e as Error).message);
  }
}

/** The winner/loser pair behind a regenerate tap. */
async function recordRegenerate(
  db: Db,
  userId: string,
  interactionId: string,
  replacedInteractionId: string,
): Promise<void> {
  const { error } = await db.from("ai_feedback").insert({
    user_id: userId,
    interaction_id: interactionId,
    kind: "regenerate",
    replaced_interaction_id: replacedInteractionId,
  });
  if (error) console.error("regenerate feedback failed:", error.message);
}

interface WindowRow {
  role: string;
  content: string;
  created_at: string;
}

/**
 * History for the next turn, guaranteed bounded.
 *
 * A conversation is stored in full, but only a window of it is ever sent to the
 * model. Once the window overflows, the older half is compressed into a single
 * `summary` message stamped at the last turn it covers, so later reads pick up
 * "summary + recent turns" and the prompt cannot grow without limit. Nothing is
 * deleted — the user's transcript stays intact.
 */
async function boundedHistory(
  db: Db,
  config: AppConfig,
  tier: Tier,
  userId: string,
  conversationId: string,
): Promise<HistoryMessage[]> {
  const maxMessages = config.int("ai_chat_history_max_messages", 12);
  const summary = await latestSummary(db, conversationId);
  let rows = await windowRows(db, conversationId, summary?.created_at ?? null);

  let summaryText = summary?.content ?? null;
  if (rows.length > maxMessages) {
    const keepRecent = Math.max(2, Math.ceil(maxMessages / 2));
    const covered = rows.slice(0, rows.length - keepRecent);
    const compressed = await compressTurns(config, tier, userId, conversationId, summaryText, covered);
    if (compressed) {
      const cutoff = covered[covered.length - 1].created_at;
      const { error } = await db.from("ai_messages").insert({
        conversation_id: conversationId,
        role: "summary",
        content: compressed,
        created_at: cutoff,
        token_count: Math.ceil(compressed.length / 4),
      });
      if (!error) {
        summaryText = compressed;
        rows = rows.slice(rows.length - keepRecent);
      }
    }
    // If compression failed, fall through: the token trim below still bounds it.
  }

  const maxTokens = config.int("ai_chat_history_max_tokens", 3000);
  const kept: HistoryMessage[] = [];
  let used = summaryText ? Math.ceil(summaryText.length / 4) : 0;
  for (let i = rows.length - 1; i >= 0; i--) {
    const approx = Math.ceil(rows[i].content.length / 4);
    if (used + approx > maxTokens && kept.length > 0) break;
    kept.unshift({ role: rows[i].role, content: rows[i].content });
    used += approx;
  }
  if (summaryText) kept.unshift({ role: "summary", content: summaryText });
  return kept;
}

async function latestSummary(
  db: Db,
  conversationId: string,
): Promise<{ content: string; created_at: string } | null> {
  const { data } = await db
    .from("ai_messages")
    .select("content, created_at")
    .eq("conversation_id", conversationId)
    .eq("role", "summary")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data as { content: string; created_at: string } | null) ?? null;
}

/** Turns after the newest summary, oldest first. */
async function windowRows(
  db: Db,
  conversationId: string,
  since: string | null,
): Promise<WindowRow[]> {
  let q = db
    .from("ai_messages")
    .select("role, content, created_at")
    .eq("conversation_id", conversationId)
    .in("role", ["user", "assistant"])
    .order("created_at", { ascending: true });
  if (since) q = q.gt("created_at", since);
  const { data } = await q;
  return (data ?? []) as WindowRow[];
}

/**
 * Fold older turns (and any previous summary) into one short recap. Our own
 * housekeeping, so it runs unmetered — but it is still logged, because
 * "compress a conversation" is one of the tasks we intend to train.
 */
async function compressTurns(
  config: AppConfig,
  tier: Tier,
  userId: string,
  conversationId: string,
  previousSummary: string | null,
  turns: WindowRow[],
): Promise<string | null> {
  if (turns.length === 0) return previousSummary;
  const transcript = turns
    .map((m) => `${m.role === "assistant" ? "Aura" : "User"}: ${m.content}`)
    .join("\n");
  const input = previousSummary
    ? `EARLIER SUMMARY:\n${previousSummary}\n\nNEW TURNS:\n${transcript}`
    : `TURNS:\n${transcript}`;

  try {
    const t0 = Date.now();
    const gen = await generateJson(config, tier, CHAT_SUMMARY_SYSTEM, input, {
      temperature: 0,
      maxTokens: 400,
    });
    const text = typeof gen.json.summary === "string" ? gen.json.summary.trim() : "";
    if (!text) return null;

    await logInteraction({
      userId,
      feature: "chat_summarise",
      model: gen.model,
      provider: gen.provider,
      latencyMs: Date.now() - t0,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      conversationId,
      payload: { input, summary: text, turns: turns.length },
    });
    return text;
  } catch {
    return null;
  }
}

function formatHistory(history: HistoryMessage[]): string {
  return history
    .map((m) =>
      m.role === "summary"
        ? `Earlier in this chat: ${m.content}`
        : `${m.role === "assistant" ? "Aura" : m.role}: ${m.content}`
    )
    .join("\n");
}

async function persistTurn(
  db: Db,
  conversationId: string,
  question: string,
  answer: string,
  citations: { node_id: string; title: string; snippet: string }[],
  requestId: string | null,
): Promise<void> {
  // Both rows would otherwise share the transaction timestamp, leaving the
  // question and its answer in an arbitrary order when history is replayed.
  const askedAt = new Date();
  const answeredAt = new Date(askedAt.getTime() + 1);

  await db.from("ai_messages").insert([
    {
      conversation_id: conversationId,
      role: "user",
      content: question,
      created_at: askedAt.toISOString(),
      token_count: Math.ceil(question.length / 4),
    },
    {
      conversation_id: conversationId,
      role: "assistant",
      content: answer,
      citations,
      request_id: requestId,
      created_at: answeredAt.toISOString(),
      token_count: Math.ceil(answer.length / 4),
    },
  ]);
  await db
    .from("ai_conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
}
