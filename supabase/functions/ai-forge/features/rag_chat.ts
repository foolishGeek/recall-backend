// Feature: rag_chat. Embed the question, retrieve owned chunks within the
// active-bucket scope, and answer with citations. Empty corpus → fixed reply,
// no LLM, no charge [§6]. Otherwise consume the gate, then call the model.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { formatContext, RetrievedChunk } from "../../_shared/context.ts";
import { openaiEmbed } from "../../_shared/providers/openai.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { gateCheck, gateConsume, assertAllowed, logUsage } from "../../_shared/quota.ts";
import { requireString, asUuidArray } from "../../_shared/validate.ts";
import { RAG_SYSTEM, RAG_EMPTY_REPLY } from "../prompts.ts";

export async function ragChat(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const question = truncate(stripHtml(requireString(payload.question, "question")), 2000);
  const requestedBuckets = asUuidArray(payload.bucket_ids);
  const requestedNodes = asUuidArray(payload.node_ids);
  const db = adminClient();

  // Maintenance / downgrade pre-flight before any retrieval work.
  const pre = await gateCheck(userId);
  assertAllowed(pre);
  const tier = (pre.tier ?? "free") as Tier;

  // Resolve the active-bucket scope server-side [AI-PROMPTS § Active bucket scope].
  const { data: activeRows, error: scopeErr } = await db.rpc("active_buckets_for_user", { uid: userId });
  if (scopeErr) throw scopeErr;
  const activeIds: string[] = (activeRows ?? []).map((b: { id: string }) => b.id);
  let scopeIds = activeIds;
  if (requestedBuckets) scopeIds = activeIds.filter((id) => requestedBuckets.includes(id));
  if (scopeIds.length === 0) {
    return { answer: RAG_EMPTY_REPLY, citations: [], model: null };
  }

  // Embed the question.
  const embedModel = config.str("ai_model_embed", "text-embedding-3-small");
  const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  const { embeddings } = await openaiEmbed(openaiKey, embedModel, [question]);
  const qEmbedding = embeddings[0] ?? [];

  const { data: matches, error: matchErr } = await db.rpc("match_chunks", {
    query_embedding: JSON.stringify(qEmbedding),
    match_user_id: userId,
    match_count: config.int("ai_rag_top_k", 8),
    match_threshold: config.num("ai_rag_similarity_threshold", 0.7),
    filter_bucket_ids: scopeIds,
    filter_node_ids: requestedNodes,
  });
  if (matchErr) throw matchErr;

  const rows = (matches ?? []) as { node_id: string; content: string; similarity: number }[];
  if (rows.length === 0) {
    return { answer: RAG_EMPTY_REPLY, citations: [], model: null };
  }

  // Titles for the retrieved nodes (for context tags + citations).
  const nodeIds = [...new Set(rows.map((r) => r.node_id))];
  const { data: titleRows } = await db.from("nodes").select("id, title").in("id", nodeIds);
  const titles = new Map<string, string>((titleRows ?? []).map((n: { id: string; title: string }) => [n.id, n.title]));

  const retrieved: RetrievedChunk[] = rows.map((r) => ({
    node_id: r.node_id,
    title: titles.get(r.node_id) ?? "",
    content: r.content,
    similarity: r.similarity,
  }));
  const ctx = formatContext(retrieved, config.int("ai_context_max_chars", 12000));

  // We have content → this is a billable request.
  const decision = await gateConsume(userId, "rag_chat");
  assertAllowed(decision);

  const userPrompt = `CONTEXT:\n${ctx.text}\n\nQUESTION:\n${question}`;
  const gen = await generateJson(config, tier, RAG_SYSTEM, userPrompt);

  const answer = typeof gen.json.answer === "string" ? gen.json.answer : "";
  const cited = Array.isArray(gen.json.cited_node_ids) ? (gen.json.cited_node_ids as string[]) : [];
  const byId = new Map(ctx.nodes.map((n) => [n.node_id, n]));
  let citations = cited
    .map((id) => byId.get(id))
    .filter((n): n is { node_id: string; title: string; snippet: string } => !!n);
  if (citations.length === 0) citations = ctx.nodes; // fall back to all retrieved

  await logUsage(userId, "rag_chat", gen.usage.input_tokens, gen.usage.output_tokens, gen.model);
  return { answer, citations, model: gen.model, usage: gen.usage };
}
