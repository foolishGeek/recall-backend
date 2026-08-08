// Feature: quiz_grade (premium). Grades a short answer against a reference +
// rubric. Empty/ungradable → suggested_grade "again" with no LLM call.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { assertAllowed, gateCheck, withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { requireString } from "../../_shared/validate.ts";
import { QUIZ_GRADE_SYSTEM } from "../prompts.ts";

const GRADES = ["again", "hard", "good", "easy"];

export async function quizGrade(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const question = requireString(payload.question, "question");
  const referenceAnswer = typeof payload.reference_answer === "string" ? payload.reference_answer : "";
  const rubric = typeof payload.grading_rubric === "string" ? payload.grading_rubric : "";
  const userAnswer = typeof payload.user_answer === "string" ? payload.user_answer.trim() : "";

  // Ungradable (empty answer) → again, no charge.
  if (!userAnswer) {
    return { is_correct: false, suggested_grade: "again", feedback: "No answer provided.", model: null };
  }

  // Whether quiz_grade is premium-only lives in ai_feature_policy, not here —
  // opening it to free users is a row update, not a redeploy.
  assertAllowed(await gateCheck(userId, "quiz_grade"));

  const db = adminClient();
  let nodeSnippet = "";
  if (typeof payload.node_id === "string") {
    const { data: node } = await db
      .from("nodes")
      .select("title, extracted_text, buckets!inner(user_id)")
      .eq("id", payload.node_id)
      .is("deleted_at", null)
      .maybeSingle();
    const owner = (node as { buckets?: { user_id?: string } } | null)?.buckets?.user_id;
    if (node && owner === userId) {
      const n = node as { title?: string; extracted_text?: string };
      nodeSnippet = `${n.title ?? ""}\n${truncate(stripHtml(n.extracted_text), 2000)}`;
    }
  }

  const userPrompt = `NODE CONTEXT:
${nodeSnippet}

QUESTION: ${question}
REFERENCE ANSWER: ${referenceAnswer}
RUBRIC: ${rubric}
STUDENT ANSWER: ${userAnswer}`;

  return withMeteredRequest({ userId, feature: "quiz_grade" }, async (reservation) => {
    const tier = reservation.tier as Tier;
    const t0 = Date.now();
    const gen = await generateJson(config, tier, QUIZ_GRADE_SYSTEM, userPrompt, {
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
    });
    const latencyMs = Date.now() - t0;

    const suggested = GRADES.includes(gen.json.suggested_grade as string)
      ? (gen.json.suggested_grade as string)
      : "again";
    const isCorrect = typeof gen.json.is_correct === "boolean" ? gen.json.is_correct : suggested !== "again";
    const feedback = typeof gen.json.feedback === "string" ? gen.json.feedback : "";

    await logInteraction({
      userId,
      feature: "quiz_grade",
      scope: { node_id: payload.node_id ?? null },
      hadNotes: nodeSnippet.length > 0,
      blend: "notes_only",
      model: gen.model,
      latencyMs,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      payload: { question, user_answer: userAnswer, suggested_grade: suggested, feedback },
    });
    return {
      result: { is_correct: isCorrect, suggested_grade: suggested, feedback, model: gen.model, usage: gen.usage },
      model: gen.model,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
    };
  });
}
