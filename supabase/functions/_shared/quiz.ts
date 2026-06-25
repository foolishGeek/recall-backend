// Shared quiz helpers. The single place that turns a stored `question_json`
// superset [D-QUIZ-1] into the client-safe payload — the answer key
// (correct_index / reference_answer / grading_rubric, and flashcard_back until
// reveal) never leaves the server. Used by quiz-generate, quiz-attempt, and the
// type-driven grading paths in quiz-submit-answer.

export type ConcreteQuestionType = "mcq" | "short_answer" | "flashcard";

/** Client-safe view of a stored question. No correctness data. */
export function redactQuestion(
  questionJson: Record<string, unknown>,
  questionAttemptId: string,
  answered = false,
): Record<string, unknown> {
  const redacted: Record<string, unknown> = {
    question_attempt_id: questionAttemptId,
    position: questionJson.position,
    type: questionJson.type,
    prompt: questionJson.prompt,
    difficulty: questionJson.difficulty ?? null,
    node_id: questionJson.node_id ?? null,
    bucket_name: questionJson.bucket_name ?? null,
    answered,
  };
  if (questionJson.type === "mcq") redacted.options = questionJson.options ?? [];
  return redacted;
}
