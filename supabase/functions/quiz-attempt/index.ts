/// <reference lib="deno.ns" />

// quiz-attempt [S18]. POST { attempt_id } -> redacted questions for resuming an
// in-progress attempt. Same redaction as quiz-generate [D-QUIZ-1] (the answer key
// never leaves the server) plus an `answered` flag per question so the client can
// continue at the first unanswered position.

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { assertAllowed, gateCheck } from "../_shared/quota.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireUuid } from "../_shared/validate.ts";
import { redactQuestion } from "../_shared/quiz.ts";

interface AttemptRow {
  id: string;
  user_id: string;
  status: string;
  question_count: number | null;
  quiz_configs: { timer_sec: number | null } | null;
}

interface QuestionRow {
  id: string;
  question_json: Record<string, unknown>;
  answered_at: string | null;
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

    const db = adminClient();

    const { data: attempt, error: attemptErr } = await db
      .from("quiz_attempts")
      .select("id, user_id, status, question_count, quiz_configs(timer_sec)")
      .eq("id", attemptId)
      .maybeSingle();
    if (attemptErr) throw attemptErr;
    if (!attempt) throw new AppError("invalid_input", "attempt not found");
    const attemptRow = attempt as unknown as AttemptRow;
    if (attemptRow.user_id !== caller.userId) throw new AppError("unauthorized");
    if (attemptRow.status !== "in_progress") {
      throw new AppError("invalid_input", "attempt is not in progress");
    }

    const gate = await gateCheck(caller.userId);
    assertAllowed(gate);
    if (gate.tier !== "premium") throw new AppError("premium_required");

    const { data: rows, error: rowsErr } = await db
      .from("quiz_question_attempts")
      .select("id, question_json, answered_at")
      .eq("attempt_id", attemptId)
      .order("position", { ascending: true });
    if (rowsErr) throw rowsErr;

    const questions = (rows ?? []).map((row) => {
      const q = row as QuestionRow;
      return redactQuestion(q.question_json ?? {}, q.id, q.answered_at != null);
    });

    return jsonResponse({
      attempt_id: attemptId,
      timer_sec: attemptRow.quiz_configs?.timer_sec ?? null,
      question_count: attemptRow.question_count ?? questions.length,
      questions,
    });
  } catch (err) {
    return toErrorResponse(err);
  }
});
