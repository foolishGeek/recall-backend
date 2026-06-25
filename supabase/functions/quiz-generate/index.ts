// quiz-generate [S17]. POST { config_id } -> persisted attempt + redacted questions.
// AI generation stays inside ai-forge; this public EF owns auth, premium gating,
// persistence, and answer-key redaction [D-QUIZ-1].

declare const Deno: {
  serve: (handler: (req: Request) => Response | Promise<Response>) => void;
};

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppConfig } from "../_shared/config.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { gateCheck, assertAllowed } from "../_shared/quota.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireUuid } from "../_shared/validate.ts";
import { quizGenerate } from "../ai-forge/features/quiz_generate.ts";
import { ModelQuestion, QuizConfigRow, redactedQuestion, resolveQuestionRows } from "./helpers.ts";

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId) throw new AppError("unauthorized");

    const body = await req.json().catch(() => ({}));
    const configId = requireUuid((body as { config_id?: unknown }).config_id, "config_id");
    const db = adminClient();

    const { data: config, error: configErr } = await db
      .from("quiz_configs")
      .select()
      .eq("id", configId)
      .maybeSingle();
    if (configErr) throw configErr;
    if (!config) throw new AppError("invalid_input", "config not found");

    const quizConfig = config as QuizConfigRow;
    if (quizConfig.user_id !== caller.userId) throw new AppError("unauthorized");

    const gate = await gateCheck(caller.userId);
    assertAllowed(gate);
    if (gate.tier !== "premium") throw new AppError("premium_required");

    const appConfig = await AppConfig.load();
    const generated = await quizGenerate(
      {
        mode: quizConfig.mode,
        bucket_ids: quizConfig.bucket_ids ?? [],
        node_ids: quizConfig.node_ids ?? [],
        prompt: quizConfig.prompt ?? "",
        use_my_notes: quizConfig.use_my_notes,
        question_count: quizConfig.question_count,
        question_type: quizConfig.question_type,
        difficulty: quizConfig.difficulty,
      },
      caller.userId,
      appConfig,
    );

    const rawQuestions = (Array.isArray(generated.questions) ? generated.questions : []) as ModelQuestion[];
    if (!rawQuestions.length) {
      throw new AppError("provider_error", "No quiz questions were generated. Try again with more note context.");
    }

    const questionRows = await resolveQuestionRows(quizConfig, rawQuestions, caller.userId);
    const actualCount = questionRows.length;

    const { data: attempt, error: attemptErr } = await db
      .from("quiz_attempts")
      .insert({
        user_id: caller.userId,
        config_id: quizConfig.id,
        mode: quizConfig.mode,
        question_type: quizConfig.question_type,
        status: "in_progress",
        question_count: actualCount,
      })
      .select("id")
      .single();
    if (attemptErr) throw attemptErr;

    const attemptId = (attempt as { id: string }).id;
    try {
      const { data: inserted, error: questionsErr } = await db
        .from("quiz_question_attempts")
        .insert(
          questionRows.map((q) => ({
            attempt_id: attemptId,
            node_id: q.node_id,
            bucket_id: q.bucket_id,
            question_json: q.question_json,
            position: q.position,
          })),
        )
        .select("id, question_json")
        .order("position", { ascending: true });
      if (questionsErr) throw questionsErr;

      return jsonResponse({
        attempt_id: attemptId,
        timer_sec: quizConfig.timer_sec,
        question_count: actualCount,
        questions: (inserted ?? []).map((row: { id: string; question_json: Record<string, unknown> }) =>
          redactedQuestion(row.question_json, row.id)
        ),
      });
    } catch (err) {
      await db.from("quiz_attempts").delete().eq("id", attemptId);
      throw err;
    }
  } catch (err) {
    return toErrorResponse(err);
  }
});
