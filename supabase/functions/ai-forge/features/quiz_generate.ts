// Feature: quiz_generate (internal — called by the quiz-generate EF in S17).
// Assembles context by mode and asks the model for question_count questions.
// The full server-side question_json superset [D-QUIZ-1] is owned by S17; here
// we return the raw model questions.
//
// [D-AI-7] freehand is topic-aware: it derives the collective topics of the
// selected scope (titles + tags), retrieves notes (with a corpus fallback),
// optionally blends web context (no-op hook), and lets the model add broader
// general-knowledge questions on the same topics. by_node/by_bucket use the
// node corpus so link/YouTube notes without extracted_text still produce a quiz.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { truncate } from "../../_shared/text.ts";
import { formatContext, RetrievedChunk } from "../../_shared/context.ts";
import { nodeCorpusText, NodeRow } from "../../_shared/node_corpus.ts";
import { openaiEmbed } from "../../_shared/providers/openai.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { gateConsume, assertAllowed, logUsage } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { webContext } from "../../_shared/web_context.ts";
import { asUuidArray } from "../../_shared/validate.ts";
import { quizGenerateSystem } from "../prompts.ts";

const CORPUS_FIELDS = "id, title, extracted_text, markdown, url, link_preview_json, bucket_id";

export async function quizGenerate(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const mode = ["freehand", "by_bucket", "by_node"].includes(payload.mode as string)
    ? (payload.mode as string)
    : "freehand";
  const questionCount = Math.max(1, Math.min(50, Number(payload.question_count) || 10));
  const difficulty = Math.max(1, Math.min(5, Number(payload.difficulty) || 3));
  const questionType = ["mcq", "short_answer", "flashcard", "mix"].includes(payload.question_type as string)
    ? (payload.question_type as string)
    : "mcq";
  const prompt = typeof payload.prompt === "string" ? payload.prompt : "";
  const useMyNotes = payload.use_my_notes !== false;
  const requestedBuckets = asUuidArray(payload.bucket_ids);
  const requestedNodes = asUuidArray(payload.node_ids);
  const db = adminClient();

  const maxChars = config.int("ai_context_max_chars", 12000);
  let context = "";
  let topics = "";
  const retrievedNodeIds = new Set<string>();

  const corpusBlocks = (rows: NodeRow[]): string => {
    const per = Math.floor(maxChars / Math.max(rows.length, 1));
    return rows
      .map((n) => {
        const text = nodeCorpusText(n);
        if (text) retrievedNodeIds.add(n.id);
        return text ? `[Node: ${n.title ?? ""} | id:${n.id}]\n${truncate(text, per)}` : "";
      })
      .filter((b) => b.length > 0)
      .join("\n---\n");
  };

  if (mode === "by_node") {
    const nodeIds = requestedNodes ?? [];
    if (nodeIds.length) {
      const { data: nodes } = await db
        .from("nodes")
        .select(`${CORPUS_FIELDS}, buckets!inner(user_id)`)
        .in("id", nodeIds)
        .is("deleted_at", null);
      const owned = (nodes ?? []).filter(
        (n: { buckets?: { user_id?: string } }) => n.buckets?.user_id === userId,
      ) as NodeRow[];
      context = corpusBlocks(owned);
    }
  } else if (mode === "by_bucket") {
    const bucketIds = requestedBuckets ?? [];
    if (bucketIds.length) {
      // Heat-weighted sample: surface weaker / more-overdue nodes first.
      const { data: nodes } = await db
        .from("nodes")
        .select(`${CORPUS_FIELDS}, comfort, due_at, buckets!inner(user_id)`)
        .in("bucket_id", bucketIds)
        .is("deleted_at", null)
        .order("comfort", { ascending: true, nullsFirst: true })
        .order("due_at", { ascending: true, nullsFirst: true })
        .limit(questionCount * 2);
      const owned = (nodes ?? []).filter(
        (n: { buckets?: { user_id?: string } }) => n.buckets?.user_id === userId,
      ) as NodeRow[];
      context = corpusBlocks(owned);
    }
  } else {
    // freehand — derive collective topics from the chosen scope, then RAG.
    const { data: activeRows } = await db.rpc("active_buckets_for_user", { uid: userId });
    const activeIds: string[] = (activeRows ?? []).map((b: { id: string }) => b.id);
    let scopeIds = activeIds;
    if (requestedBuckets?.length) scopeIds = activeIds.filter((id) => requestedBuckets.includes(id));

    if (useMyNotes && scopeIds.length) {
      // Collective topics: titles + tags across the scope (capped).
      let topicQ = db
        .from("nodes")
        .select("id, title")
        .in("bucket_id", scopeIds)
        .is("deleted_at", null)
        .limit(40);
      if (requestedNodes?.length) topicQ = topicQ.in("id", requestedNodes);
      const { data: topicNodes } = await topicQ;
      const titles = [...new Set((topicNodes ?? []).map((n: { title?: string }) => (n.title ?? "").trim()).filter(Boolean))];
      const ids = (topicNodes ?? []).map((n: { id: string }) => n.id);
      let tagNames: string[] = [];
      if (ids.length) {
        const { data: tagRows } = await db.from("node_tags").select("tags(name)").in("node_id", ids);
        tagNames = [...new Set(
          (tagRows ?? []).map((r: { tags?: { name?: string } }) => r.tags?.name ?? "").filter(Boolean),
        )];
      }
      topics = [...titles.slice(0, 12), ...tagNames.slice(0, 8)].join(", ");

      // RAG over the scope using the prompt + collective topics as the query.
      const embedModel = config.str("ai_model_embed", "text-embedding-3-small");
      const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
      const query = [prompt, topics].filter(Boolean).join(". ") || "key themes";
      const { embeddings } = await openaiEmbed(openaiKey, embedModel, [query]);
      const { data: matches } = await db.rpc("match_chunks", {
        query_embedding: JSON.stringify(embeddings[0] ?? []),
        match_user_id: userId,
        match_count: config.int("ai_rag_top_k", 8),
        match_threshold: config.num("ai_rag_similarity_threshold", 0.7),
        filter_bucket_ids: scopeIds,
        filter_node_ids: requestedNodes,
      });
      const rows = (matches ?? []) as { node_id: string; content: string; similarity: number }[];
      if (rows.length) {
        for (const r of rows) retrievedNodeIds.add(r.node_id);
        const retrieved: RetrievedChunk[] = rows.map((r) => ({
          node_id: r.node_id,
          title: "",
          content: r.content,
          similarity: r.similarity,
        }));
        context = formatContext(retrieved, maxChars).text;
      } else {
        // No embedded chunks yet → corpus fallback over the scope.
        let q = db.from("nodes").select(CORPUS_FIELDS).in("bucket_id", scopeIds).is("deleted_at", null).limit(20);
        if (requestedNodes?.length) q = q.in("id", requestedNodes);
        const { data: nodeRows } = await q;
        context = corpusBlocks((nodeRows ?? []) as NodeRow[]);
      }
    }

    // Web grounding hook (no-op today) — merged into context when enabled.
    const web = await webContext([prompt, topics].filter(Boolean).join(". "), config);
    if (web.text) context = [context, `[Web]\n${web.text}`].filter(Boolean).join("\n---\n");
  }

  const decision = await gateConsume(userId, "quiz_generate");
  assertAllowed(decision);
  const tier = (decision.tier ?? "free") as Tier;

  const system = quizGenerateSystem(questionCount, difficulty, questionType) + (await userDirectives(userId));
  const userPrompt = `TOPICS: ${topics || "(from the user prompt)"}
CONTEXT:
${context || "(no notes provided)"}

USER PROMPT (freehand only): ${prompt}

Generate ${questionCount} questions of type ${questionType}.`;
  const t0 = Date.now();
  const gen = await generateJson(config, tier, system, userPrompt);
  const latencyMs = Date.now() - t0;

  const questions = Array.isArray(gen.json.questions) ? gen.json.questions : [];

  await logUsage(userId, "quiz_generate", gen.usage.input_tokens, gen.usage.output_tokens, gen.model);
  const hadNotes = context.length > 0;
  await logInteraction({
    userId,
    feature: "quiz_generate",
    scope: { mode, bucket_ids: requestedBuckets ?? null, node_ids: requestedNodes ?? null, topics },
    retrievedNodeIds: [...retrievedNodeIds],
    hadNotes,
    blend: hadNotes ? "blended" : "general_only",
    model: gen.model,
    latencyMs,
    inputTokens: gen.usage.input_tokens,
    outputTokens: gen.usage.output_tokens,
    payload: { prompt, topics, context, question_count: questionCount, question_type: questionType },
  });
  return { questions, model: gen.model, usage: gen.usage };
}
