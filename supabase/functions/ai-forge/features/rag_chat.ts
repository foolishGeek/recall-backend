// Feature: rag_chat. Embed the question, retrieve owned chunks within the
// active-bucket scope, then answer with citations. Policy [D-AI-5]: answers are
// BLENDED — notes-first, enriched with general knowledge. Vector misses fall
// back to the nodes' direct corpus at every scope; an empty corpus still calls
// the model (general knowledge) and counts as one AI request.

import { adminClient } from "../../_shared/supabase.ts";
import { resolveScope } from "../../_shared/scope.ts";
import { AppConfig } from "../../_shared/config.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { formatContext, RetrievedChunk } from "../../_shared/context.ts";
import { nodeCorpusText, NodeRow } from "../../_shared/node_corpus.ts";
import { embedQuery } from "../../_shared/providers/embed.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { assertAllowed, gateCheck, MeterInput, withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireString, asUuidArray } from "../../_shared/validate.ts";
import { RAG_SYSTEM } from "../prompts.ts";

// Cap how many nodes we pull for the corpus fallback before char-trimming.
const MAX_FALLBACK_NODES = 40;

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
  const scopeIds = scope.bucketIds;

  let retrieved: RetrievedChunk[] = [];

  if (!scope.isEmpty) {
    // Embed the question and try vector retrieval first. A null vector means
    // embedding is unavailable right now; the corpus fallback below still runs.
    const qEmbedding = await embedQuery(config, question);

    const { data: matches, error: matchErr } = qEmbedding
      ? await db.rpc("match_chunks", {
        query_embedding: JSON.stringify(qEmbedding),
        match_user_id: userId,
        match_count: config.int("ai_rag_top_k", 8),
        match_threshold: config.num("ai_rag_similarity_threshold", 0.7),
        filter_bucket_ids: scopeIds,
        filter_node_ids: scope.nodeIds,
      })
      : { data: null, error: null };
    if (matchErr) throw matchErr;

    const rows = (matches ?? []) as { node_id: string; content: string; similarity: number }[];

    if (rows.length > 0) {
      const nodeIds = [...new Set(rows.map((r) => r.node_id))];
      const { data: titleRows } = await db.from("nodes").select("id, title").in("id", nodeIds);
      const titles = new Map<string, string>(
        (titleRows ?? []).map((n: { id: string; title: string }) => [n.id, n.title]),
      );
      retrieved = rows.map((r) => ({
        node_id: r.node_id,
        title: titles.get(r.node_id) ?? "",
        content: r.content,
        similarity: r.similarity,
      }));
    } else {
      // Vector miss — fall back to the nodes' direct corpus so chat works even
      // when chunks were never embedded (e.g. empty extracted_text). Scoped to
      // the requested nodes when present, otherwise the whole active scope.
      let q = db
        .from("nodes")
        .select("id, title, extracted_text, markdown, url, link_preview_json, bucket_id")
        .in("bucket_id", scopeIds)
        .is("deleted_at", null);
      if (requestedNodes?.length) q = q.in("id", requestedNodes);
      const { data: nodeRows, error: nodeErr } = await q.limit(MAX_FALLBACK_NODES);
      if (nodeErr) throw nodeErr;

      retrieved = (nodeRows ?? [])
        .map((n: NodeRow) => {
          const content = nodeCorpusText(n);
          if (!content) return null;
          return {
            node_id: n.id,
            title: n.title ?? "",
            content,
            similarity: 1,
          } satisfies RetrievedChunk;
        })
        .filter((c): c is RetrievedChunk => c !== null);
    }
  }

  const ctx = formatContext(retrieved, config.int("ai_context_max_chars", 12000));

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
