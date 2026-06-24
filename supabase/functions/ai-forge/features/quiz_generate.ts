// Feature: quiz_generate (internal — called by the quiz-generate EF in S17).
// Assembles context by mode and asks the model for question_count questions.
// The full server-side question_json superset [D-QUIZ-1] is owned by S17; here
// we return the raw model questions.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { formatContext, RetrievedChunk } from "../../_shared/context.ts";
import { openaiEmbed } from "../../_shared/providers/openai.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { gateConsume, assertAllowed, logUsage } from "../../_shared/quota.ts";
import { asUuidArray } from "../../_shared/validate.ts";
import { quizGenerateSystem } from "../prompts.ts";

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
  const db = adminClient();

  const maxChars = config.int("ai_context_max_chars", 12000);
  let context = "";

  if (mode === "by_node") {
    const nodeIds = asUuidArray(payload.node_ids) ?? [];
    if (nodeIds.length) {
      const { data: nodes } = await db
        .from("nodes")
        .select("title, extracted_text, buckets!inner(user_id)")
        .in("id", nodeIds)
        .is("deleted_at", null);
      const owned = (nodes ?? []).filter(
        (n: { buckets?: { user_id?: string } }) => n.buckets?.user_id === userId,
      );
      const per = Math.floor(maxChars / Math.max(owned.length, 1));
      context = owned
        .map((n: { title?: string; extracted_text?: string }) =>
          `[Node: ${n.title ?? ""}]\n${truncate(stripHtml(n.extracted_text), per)}`
        )
        .join("\n---\n");
    }
  } else if (mode === "by_bucket") {
    const bucketIds = asUuidArray(payload.bucket_ids) ?? [];
    if (bucketIds.length) {
      const { data: nodes } = await db
        .from("nodes")
        .select("title, extracted_text, buckets!inner(user_id)")
        .in("bucket_id", bucketIds)
        .is("deleted_at", null)
        .limit(questionCount * 2);
      const owned = (nodes ?? []).filter(
        (n: { buckets?: { user_id?: string } }) => n.buckets?.user_id === userId,
      );
      const per = Math.floor(maxChars / Math.max(owned.length, 1));
      context = owned
        .map((n: { title?: string; extracted_text?: string }) =>
          `[Node: ${n.title ?? ""}]\n${truncate(stripHtml(n.extracted_text), per)}`
        )
        .join("\n---\n");
    }
  } else if (useMyNotes && prompt) {
    // freehand with notes → retrieve relevant chunks over the active scope.
    const { data: activeRows } = await db.rpc("active_buckets_for_user", { uid: userId });
    const scopeIds: string[] = (activeRows ?? []).map((b: { id: string }) => b.id);
    if (scopeIds.length) {
      const embedModel = config.str("ai_model_embed", "text-embedding-3-small");
      const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
      const { embeddings } = await openaiEmbed(openaiKey, embedModel, [prompt]);
      const { data: matches } = await db.rpc("match_chunks", {
        query_embedding: JSON.stringify(embeddings[0] ?? []),
        match_user_id: userId,
        match_count: config.int("ai_rag_top_k", 8),
        match_threshold: config.num("ai_rag_similarity_threshold", 0.7),
        filter_bucket_ids: scopeIds,
        filter_node_ids: null,
      });
      const rows = (matches ?? []) as { node_id: string; content: string; similarity: number }[];
      const retrieved: RetrievedChunk[] = rows.map((r) => ({
        node_id: r.node_id,
        title: "",
        content: r.content,
        similarity: r.similarity,
      }));
      context = formatContext(retrieved, maxChars).text;
    }
  }

  const decision = await gateConsume(userId, "quiz_generate");
  assertAllowed(decision);
  const tier = (decision.tier ?? "free") as Tier;

  const system = quizGenerateSystem(questionCount, difficulty, questionType);
  const userPrompt = `CONTEXT:\n${context || "(no notes provided)"}\n\nUSER PROMPT (freehand only): ${prompt}\n\nGenerate ${questionCount} questions of type ${questionType}.`;
  const gen = await generateJson(config, tier, system, userPrompt);

  const questions = Array.isArray(gen.json.questions) ? gen.json.questions : [];

  await logUsage(userId, "quiz_generate", gen.usage.input_tokens, gen.usage.output_tokens, gen.model);
  return { questions, model: gen.model, usage: gen.usage };
}
