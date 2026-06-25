// Type-driven grading for quiz-submit-answer [S18]. Server is authoritative: the
// MCQ key (`correct_index`) and the short-answer reference live only in the
// stored question_json and are never returned to the client during play.

import { AppConfig } from "../_shared/config.ts";
import { AppError } from "../_shared/errors.ts";
import { quizGrade } from "../ai-forge/features/quiz_grade.ts";

export const GRADES = ["again", "hard", "good", "easy"] as const;
export type Grade = (typeof GRADES)[number];

export interface GradeResult {
  grade: Grade | null;
  isCorrect: boolean | null;
  feedback: string | null;
  userAnswer: string | null;
  /** Short-answer AI grading was unavailable; resolved later at quiz-complete. */
  pending: boolean;
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

/** Timer expiry / explicit skip → counts as a lapse, no answer stored [09a]. */
export function gradeTimedOut(): GradeResult {
  return { grade: "again", isCorrect: false, feedback: null, userAnswer: null, pending: false };
}

export function gradeMcq(questionJson: Record<string, unknown>, selectedIndex: unknown): GradeResult {
  const options = Array.isArray(questionJson.options) ? (questionJson.options as unknown[]) : [];
  const correctIndex = Number.isInteger(questionJson.correct_index)
    ? (questionJson.correct_index as number)
    : -1;

  if (!Number.isInteger(selectedIndex) || (selectedIndex as number) < 0 || (selectedIndex as number) >= options.length) {
    // No / invalid selection → treated as wrong, nothing stored.
    return { grade: "again", isCorrect: false, feedback: null, userAnswer: null, pending: false };
  }

  const idx = selectedIndex as number;
  const isCorrect = idx === correctIndex;
  return {
    grade: isCorrect ? "good" : "again",
    isCorrect,
    feedback: null,
    userAnswer: asString(options[idx]),
    pending: false,
  };
}

export function gradeFlashcard(flashcardGrade: unknown): GradeResult {
  if (typeof flashcardGrade !== "string" || !GRADES.includes(flashcardGrade as Grade)) {
    throw new AppError("invalid_input", "flashcard_grade must be one of again|hard|good|easy");
  }
  const grade = flashcardGrade as Grade;
  return {
    grade,
    isCorrect: grade === "good" || grade === "easy",
    feedback: null,
    userAnswer: null,
    pending: false,
  };
}

export async function gradeShortAnswer(
  questionJson: Record<string, unknown>,
  rawAnswer: unknown,
  nodeId: string | null,
  userId: string,
  config: AppConfig,
): Promise<GradeResult> {
  const userAnswer = typeof rawAnswer === "string" ? rawAnswer.trim() : "";
  if (!userAnswer) {
    return { grade: "again", isCorrect: false, feedback: "No answer provided.", userAnswer: "", pending: false };
  }

  try {
    const result = await quizGrade(
      {
        question: asString(questionJson.prompt) ?? "",
        reference_answer: asString(questionJson.reference_answer) ?? "",
        grading_rubric: asString(questionJson.grading_rubric) ?? "",
        user_answer: userAnswer,
        node_id: nodeId ?? undefined,
      },
      userId,
      config,
    );
    return {
      grade: (result.suggested_grade as Grade) ?? "again",
      isCorrect: typeof result.is_correct === "boolean" ? result.is_correct : null,
      feedback: typeof result.feedback === "string" ? result.feedback : null,
      userAnswer,
      pending: false,
    };
  } catch (err) {
    // AI provider unavailable → store the answer, resolve grade at quiz-complete.
    if (err instanceof AppError && (err.code === "provider_error" || err.code === "maintenance")) {
      return { grade: null, isCorrect: null, feedback: null, userAnswer, pending: true };
    }
    throw err;
  }
}
