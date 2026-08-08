// Quiz-specific JSON generation. Quiz payloads are large and structured, so
// this path prefers OpenAI's json_object mode regardless of tier, batches into
// small chunks, and salvages truncated arrays when a provider runs out of
// output tokens. The retry/fallback ladder itself is the shared one in
// providers/route.ts — only the ordering and the salvage rule differ.

import { AppConfig } from "../_shared/config.ts";
import { AppError } from "../_shared/errors.ts";
import { DEFAULT_TIMEOUT_MS } from "../_shared/providers/http.ts";
import { salvageObjects } from "../_shared/providers/json.ts";
import { Candidate, runLadder, sumUsage } from "../_shared/providers/route.ts";
import { openaiGenerateJson } from "../_shared/providers/openai.ts";
import { anthropicGenerateJson } from "../_shared/providers/anthropic.ts";
import { Usage } from "../_shared/providers/types.ts";

const BATCH_SIZE = 4;
const CONCRETE_TYPES = ["mcq", "short_answer", "flashcard"] as const;
type ConcreteType = (typeof CONCRETE_TYPES)[number];

interface QuizBatch {
  startPosition: number;
  types: ConcreteType[];
}

export function normalizeQuestions(json: Record<string, unknown>): Record<string, unknown>[] {
  const raw = json.questions ?? json.data;
  if (!Array.isArray(raw)) return [];
  return raw.filter((q): q is Record<string, unknown> => q != null && typeof q === "object");
}

/** Recovers the questions that completed before the model was cut off. */
function salvageQuizJson(text: string): Record<string, unknown> | null {
  const objects = salvageObjects(text, (o) => typeof o.prompt === "string");
  return objects.length ? { questions: objects } : null;
}

function concreteTypeForPosition(questionType: string, position: number): ConcreteType {
  if (questionType === "mix") return CONCRETE_TYPES[position % CONCRETE_TYPES.length];
  if (CONCRETE_TYPES.includes(questionType as ConcreteType)) return questionType as ConcreteType;
  return "mcq";
}

function planBatches(questionCount: number, questionType: string): QuizBatch[] {
  const batches: QuizBatch[] = [];
  for (let pos = 0; pos < questionCount; pos += BATCH_SIZE) {
    const count = Math.min(BATCH_SIZE, questionCount - pos);
    const types: ConcreteType[] = [];
    for (let i = 0; i < count; i++) {
      types.push(concreteTypeForPosition(questionType, pos + i));
    }
    batches.push({ startPosition: pos, types });
  }
  return batches;
}

function typeSchemaExample(type: ConcreteType): string {
  switch (type) {
    case "short_answer":
      return `{"position":0,"type":"short_answer","prompt":"question text","reference_answer":"ideal answer","grading_rubric":"what counts as correct","explanation":"brief note","source_node_ids":[]}`;
    case "flashcard":
      return `{"position":0,"type":"flashcard","prompt":"front of card","flashcard_back":"back of card","explanation":"","source_node_ids":[]}`;
    default:
      return `{"position":0,"type":"mcq","prompt":"question text","options":["A","B","C","D"],"correct_index":0,"explanation":"why the answer is correct","source_node_ids":[]}`;
  }
}

function batchTypeInstructions(batch: QuizBatch): string {
  const lines = batch.types.map((type, i) => {
    const pos = batch.startPosition + i;
    return `  position ${pos}: type "${type}" — example: ${typeSchemaExample(type)}`;
  });
  return `This batch (${batch.types.length} questions):\n${lines.join("\n")}`;
}

function batchOutputBudget(batch: QuizBatch): number {
  const per = batch.types.some((t) => t === "mcq") ? 380 : 320;
  return Math.min(4096, 300 + batch.types.length * per);
}

/** OpenAI first for json_object mode; Anthropic as the retryable fallback. */
function quizCandidates(config: AppConfig): Candidate[] {
  return [
    {
      provider: "openai",
      generate: openaiGenerateJson,
      apiKey: Deno.env.get("OPENAI_API_KEY") ?? "",
      model: config.str("ai_model_fallback", "gpt-4o-mini"),
    },
    {
      provider: "anthropic",
      generate: anthropicGenerateJson,
      apiKey: Deno.env.get("ANTHROPIC_API_KEY") ?? "",
      model: config.str("ai_model_premium", "claude-sonnet-4-20250514"),
    },
  ];
}

/** Generate all quiz questions in small batches with reliable JSON output. */
export async function generateQuizQuestions(params: {
  config: AppConfig;
  system: string;
  userPrompt: string;
  questionCount: number;
  questionType: string;
  temperature?: number;
  signal?: AbortSignal;
}): Promise<{ questions: Record<string, unknown>[]; model: string; usage: Usage }> {
  const { config, system, userPrompt, questionCount, questionType } = params;
  const candidates = quizCandidates(config);

  const allQuestions: Record<string, unknown>[] = [];
  let totalUsage: Usage = { input_tokens: 0, output_tokens: 0 };
  let modelUsed = config.str("ai_model_fallback", "gpt-4o-mini");

  for (const batch of planBatches(questionCount, questionType)) {
    const user = `${userPrompt}

${batchTypeInstructions(batch)}
Generate exactly ${batch.types.length} questions at positions ${batch.startPosition} through ${
      batch.startPosition + batch.types.length - 1
    }.
Return JSON: { "questions": [ ... ] } with one object per position. Use the exact type for each position.`;

    const result = await runLadder(candidates, system, user, {
      maxTokens: batchOutputBudget(batch),
      temperature: params.temperature,
      signal: params.signal,
      timeoutMs: config.int("ai_provider_timeout_ms", DEFAULT_TIMEOUT_MS),
      salvage: salvageQuizJson,
      accept: (json) => normalizeQuestions(json).length > 0,
    });

    allQuestions.push(...normalizeQuestions(result.json));
    totalUsage = sumUsage(totalUsage, result.usage);
    modelUsed = result.model;
  }

  const trimmed = allQuestions.slice(0, questionCount);
  if (!trimmed.length) {
    throw new AppError(
      "provider_error",
      "No quiz questions were generated. Try fewer questions or add more note content.",
    );
  }

  return { questions: trimmed, model: modelUsed, usage: totalUsage };
}
