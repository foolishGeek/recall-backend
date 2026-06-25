/// <reference lib="deno.ns" />

// quiz-submit-answer [S18]. POST one answer for an in-progress attempt. Grading
// is server-authoritative: MCQ vs question_json.correct_index, short answer via
// ai-forge quiz_grade, flashcard self-rate. Idempotent per question attempt
// [D-EF-8] — a re-submit returns the stored grade and never re-charges AI.

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppConfig } from "../_shared/config.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { assertAllowed, gateCheck } from "../_shared/quota.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireUuid } from "../_shared/validate.ts";
import {
  gradeFlashcard,
  gradeMcq,
  gradeShortAnswer,
  gradeTimedOut,
  GradeResult,
} from "./grading.ts";

interface AttemptRow {
  id: string;
  user_id: string;
  status: string;
}

interface QuestionRow {
  id: string;
  attempt_id: string;
  node_id: string | null;
  question_json: Record<string, unknown>;
  answered_at: string | null;
  user_answer: string | null;
  grade: string | null;
  is_correct: boolean | null;
  ai_feedback: string | null;
}

function asResponse(result: GradeResult, extra: Record<string, unknown> = {}) {
  const body: Record<string, unknown> = { pending: result.pending, ...extra };
  if (result.grade != null) body.grade = result.grade;
  if (result.isCorrect != null) body.is_correct = result.isCorrect;
  if (result.feedback != null) body.ai_feedback = result.feedback;
  return jsonResponse(body);
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId) throw new AppError("unauthorized");

    const body = await req.json().catch(() => ({}));
    const attemptId = requireUuid((body as { attempt_id?: unknown }).attempt_id, "attempt_id");
    const questionAttemptId = requireUuid(
      (body as { question_attempt_id?: unknown }).question_attempt_id,
      "question_attempt_id",
    );
    const revealOnly = (body as { reveal_only?: unknown }).reveal_only === true;
    const timedOut = (body as { timed_out?: unknown }).timed_out === true;
    const responseMs = Number.isInteger((body as { response_ms?: unknown }).response_ms)
      ? (body as { response_ms: number }).response_ms
      : null;

    const db = adminClient();

    const { data: attempt, error: attemptErr } = await db
      .from("quiz_attempts")
      .select("id, user_id, status")
      .eq("id", attemptId)
      .maybeSingle();
    if (attemptErr) throw attemptErr;
    if (!attempt) throw new AppError("invalid_input", "attempt not found");
    const attemptRow = attempt as AttemptRow;
    if (attemptRow.user_id !== caller.userId) throw new AppError("unauthorized");
    if (attemptRow.status !== "in_progress") {
      throw new AppError("invalid_input", "attempt is not in progress");
    }

    // Quiz is premium-only; the gate also blocks maintenance/downgrade.
    const gate = await gateCheck(caller.userId);
    assertAllowed(gate);
    if (gate.tier !== "premium") throw new AppError("premium_required");

    const { data: question, error: questionErr } = await db
      .from("quiz_question_attempts")
      .select("id, attempt_id, node_id, question_json, answered_at, user_answer, grade, is_correct, ai_feedback")
      .eq("id", questionAttemptId)
      .maybeSingle();
    if (questionErr) throw questionErr;
    if (!question) throw new AppError("invalid_input", "question not found");
    const questionRow = question as QuestionRow;
    if (questionRow.attempt_id !== attemptId) throw new AppError("invalid_input", "question/attempt mismatch");

    const questionJson = questionRow.question_json ?? {};

    // Flashcard reveal: hand back the stored back; nothing is persisted yet.
    if (revealOnly) {
      return jsonResponse({ flashcard_back: (questionJson.flashcard_back as string) ?? "" });
    }

    // Idempotent replay — return the stored grade, no re-grade / re-charge.
    if (questionRow.answered_at != null) {
      return jsonResponse({
        pending: questionRow.grade == null,
        ...(questionRow.grade != null ? { grade: questionRow.grade } : {}),
        ...(questionRow.is_correct != null ? { is_correct: questionRow.is_correct } : {}),
        ...(questionRow.ai_feedback != null ? { ai_feedback: questionRow.ai_feedback } : {}),
      });
    }

    let result: GradeResult;
    if (timedOut) {
      result = gradeTimedOut();
    } else {
      const type = questionJson.type as string;
      if (type === "mcq") {
        result = gradeMcq(questionJson, (body as { selected_index?: unknown }).selected_index);
      } else if (type === "flashcard") {
        result = gradeFlashcard((body as { flashcard_grade?: unknown }).flashcard_grade);
      } else {
        const config = await AppConfig.load();
        result = await gradeShortAnswer(
          questionJson,
          (body as { user_answer?: unknown }).user_answer,
          questionRow.node_id,
          caller.userId,
          config,
        );
      }
    }

    let comfortBefore: number | null = null;
    if (questionRow.node_id) {
      const { data: node } = await db
        .from("nodes")
        .select("comfort")
        .eq("id", questionRow.node_id)
        .maybeSingle();
      const comfort = (node as { comfort?: number } | null)?.comfort;
      comfortBefore = typeof comfort === "number" ? comfort : null;
    }

    // Guarded on answered_at IS NULL so a concurrent submit can't double-write.
    const { error: updateErr } = await db
      .from("quiz_question_attempts")
      .update({
        user_answer: result.userAnswer,
        grade: result.grade,
        is_correct: result.isCorrect,
        ai_feedback: result.feedback,
        response_ms: responseMs,
        comfort_before: comfortBefore,
        timed_out: timedOut,
        answered_at: new Date().toISOString(),
      })
      .eq("id", questionAttemptId)
      .is("answered_at", null);
    if (updateErr) throw updateErr;

    return asResponse(result);
  } catch (err) {
    return toErrorResponse(err);
  }
});
