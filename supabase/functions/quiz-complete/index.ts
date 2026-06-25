/// <reference lib="deno.ns" />

// quiz-complete [S19]. POST { attempt_id } -> graded results payload [D-EF-3].
// Orchestrates auth + premium gating + resolving any short answers S18 left
// pending (AI was unavailable mid-play), then hands the grade/score/engine/XP
// work to the server-authoritative quiz_complete_rpc. Idempotent: re-calling a
// completed attempt re-reads the results without double-writing reviews or XP.

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppConfig } from "../_shared/config.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { assertAllowed, gateCheck } from "../_shared/quota.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireUuid } from "../_shared/validate.ts";
import { quizGrade } from "../ai-forge/features/quiz_grade.ts";

interface AttemptRow {
  id: string;
  user_id: string;
  status: string;
}

interface PendingRow {
  id: string;
  node_id: string | null;
  user_answer: string | null;
  question_json: Record<string, unknown>;
}

/** Resolve short answers left pending by S18 (AI 503) before final grading. */
async function resolvePending(
  // deno-lint-ignore no-explicit-any
  db: any,
  attemptId: string,
  userId: string,
): Promise<void> {
  const { data: pending, error } = await db
    .from("quiz_question_attempts")
    .select("id, node_id, user_answer, question_json")
    .eq("attempt_id", attemptId)
    .not("answered_at", "is", null)
    .is("grade", null);
  if (error) throw error;

  const rows = (pending ?? []) as PendingRow[];
  if (rows.length === 0) return;

  const config = await AppConfig.load();
  for (const row of rows) {
    const qj = row.question_json ?? {};
    if (qj.type !== "short_answer") continue;
    try {
      const graded = await quizGrade(
        {
          question: (qj.prompt as string) ?? "",
          reference_answer: (qj.reference_answer as string) ?? "",
          grading_rubric: (qj.grading_rubric as string) ?? "",
          user_answer: row.user_answer ?? "",
          node_id: row.node_id ?? undefined,
        },
        userId,
        config,
      );
      await db
        .from("quiz_question_attempts")
        .update({
          grade: graded.suggested_grade,
          is_correct: graded.is_correct,
          ai_feedback: graded.feedback,
        })
        .eq("id", row.id)
        .is("grade", null);
    } catch (err) {
      // AI still unavailable → leave NULL; quiz_complete_rpc grades it `again`.
      console.error("quiz-complete pending grade failed:", (err as Error)?.message);
    }
  }
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
      .select("id, user_id, status")
      .eq("id", attemptId)
      .maybeSingle();
    if (attemptErr) throw attemptErr;
    if (!attempt) throw new AppError("invalid_input", "attempt not found");
    const attemptRow = attempt as AttemptRow;
    if (attemptRow.user_id !== caller.userId) throw new AppError("unauthorized");
    if (attemptRow.status === "abandoned") {
      throw new AppError("invalid_input", "attempt was abandoned");
    }

    // Quiz is premium-only; the gate also blocks maintenance/downgrade.
    const gate = await gateCheck(caller.userId);
    assertAllowed(gate);
    if (gate.tier !== "premium") throw new AppError("premium_required");

    // Only an in-progress attempt needs grading work; a completed attempt just
    // re-reads its results below (idempotent retry).
    if (attemptRow.status === "in_progress") {
      await resolvePending(db, attemptId, caller.userId);
    }

    const { data: result, error: rpcErr } = await db.rpc("quiz_complete_rpc", {
      p_user: caller.userId,
      p_attempt_id: attemptId,
    });
    if (rpcErr) throw rpcErr;

    return jsonResponse(result);
  } catch (err) {
    console.error("quiz-complete error:", (err as Error)?.message);
    return toErrorResponse(err);
  }
});
