// Quiz-specific JSON generation. Uses OpenAI json_object mode first (most reliable
// for large structured payloads), batches into small chunks, and salvages
// truncated arrays when a provider runs out of output tokens.

import { AppConfig } from "../_shared/config.ts";
import { AppError } from "../_shared/errors.ts";
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

interface BatchResult {
  json: Record<string, unknown>;
  model: string;
  usage: Usage;
}

export function normalizeQuestions(json: Record<string, unknown>): Record<string, unknown>[] {
  const raw = json.questions ?? json.data;
  if (!Array.isArray(raw)) return [];
  return raw.filter((q): q is Record<string, unknown> => q != null && typeof q === "object");
}

function parseJsonLoose(text: string): Record<string, unknown> | null {
  if (!text) return null;
  const cleaned = text.trim().replace(/^```(?:json)?/i, "").replace(/```$/i, "").trim();
  try {
    return JSON.parse(cleaned);
  } catch {
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(cleaned.slice(start, end + 1));
      } catch {
        return salvageQuizJson(cleaned.slice(start));
      }
    }
    return salvageQuizJson(cleaned);
  }
}

/** Pull complete question objects out of a truncated JSON blob. */
function salvageQuizJson(text: string): Record<string, unknown> | null {
  const objects: Record<string, unknown>[] = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escape = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (escape) escape = false;
      else if (ch === "\\") escape = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "{") {
      if (depth === 0) start = i;
      depth++;
      continue;
    }
    if (ch === "}") {
      depth--;
      if (depth === 0 && start >= 0) {
        const slice = text.slice(start, i + 1);
        try {
          const obj = JSON.parse(slice);
          if (obj && typeof obj === "object" && typeof obj.prompt === "string") {
            objects.push(obj as Record<string, unknown>);
          }
        } catch {
          // skip malformed object
        }
        start = -1;
      }
    }
  }

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

async function callProvider(
  gen: typeof openaiGenerateJson,
  apiKey: string,
  model: string,
  system: string,
  user: string,
  maxTokens: number,
): Promise<{ text: string; usage: Usage }> {
  const res = await gen({ system, user, apiKey, model, maxTokens });
  return { text: res.text, usage: res.usage };
}

async function generateBatch(
  config: AppConfig,
  system: string,
  baseUserPrompt: string,
  batch: QuizBatch,
): Promise<BatchResult> {
  const user = `${baseUserPrompt}

${batchTypeInstructions(batch)}
Generate exactly ${batch.types.length} questions at positions ${batch.startPosition} through ${
    batch.startPosition + batch.types.length - 1
  }.
Return JSON: { "questions": [ ... ] } with one object per position. Use the exact type for each position.`;

  const maxTokens = batchOutputBudget(batch);
  const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  const openaiModel = config.str("ai_model_fallback", "gpt-4o-mini");
  const anthropicModel = config.str("ai_model_premium", "claude-sonnet-4-20250514");

  const jsonReminder = "\n\nIMPORTANT: Return a single JSON object with a questions array. No markdown.";

  // OpenAI json_object mode is the most reliable for quiz payloads.
  if (openaiKey) {
    try {
      const first = await callProvider(openaiGenerateJson, openaiKey, openaiModel, system, user, maxTokens);
      let parsed = parseJsonLoose(first.text);
      if (!parsed?.questions) {
        const second = await callProvider(
          openaiGenerateJson,
          openaiKey,
          openaiModel,
          system,
          user + jsonReminder,
          maxTokens,
        );
        parsed = parseJsonLoose(second.text);
        if (parsed) {
          return {
            json: parsed,
            model: openaiModel,
            usage: {
              input_tokens: first.usage.input_tokens + second.usage.input_tokens,
              output_tokens: first.usage.output_tokens + second.usage.output_tokens,
            },
          };
        }
      } else {
        return { json: parsed, model: openaiModel, usage: first.usage };
      }
    } catch (err) {
      console.error("OpenAI quiz batch failed:", err);
    }
  }

  if (anthropicKey) {
    const first = await callProvider(
      anthropicGenerateJson,
      anthropicKey,
      anthropicModel,
      system,
      user,
      maxTokens,
    );
    let parsed = parseJsonLoose(first.text);
    if (!parsed?.questions) {
      const second = await callProvider(
        anthropicGenerateJson,
        anthropicKey,
        anthropicModel,
        system,
        user + jsonReminder,
        maxTokens,
      );
      parsed = parseJsonLoose(second.text);
      if (!parsed?.questions) throw new AppError("provider_error", "Model did not return valid JSON.");
      return {
        json: parsed,
        model: anthropicModel,
        usage: {
          input_tokens: first.usage.input_tokens + second.usage.input_tokens,
          output_tokens: first.usage.output_tokens + second.usage.output_tokens,
        },
      };
    }
    return { json: parsed, model: anthropicModel, usage: first.usage };
  }

  throw new AppError("provider_error", "No AI provider configured for quiz generation.");
}

/** Generate all quiz questions in small batches with reliable JSON output. */
export async function generateQuizQuestions(params: {
  config: AppConfig;
  system: string;
  userPrompt: string;
  questionCount: number;
  questionType: string;
}): Promise<{ questions: Record<string, unknown>[]; model: string; usage: Usage }> {
  const { config, system, userPrompt, questionCount, questionType } = params;
  const batches = planBatches(questionCount, questionType);

  const allQuestions: Record<string, unknown>[] = [];
  const totalUsage: Usage = { input_tokens: 0, output_tokens: 0 };
  let modelUsed = config.str("ai_model_fallback", "gpt-4o-mini");

  for (const batch of batches) {
    const result = await generateBatch(config, system, userPrompt, batch);
    const qs = normalizeQuestions(result.json);
    if (!qs.length) {
      throw new AppError("provider_error", "Model did not return valid JSON.");
    }
    allQuestions.push(...qs);
    totalUsage.input_tokens += result.usage.input_tokens;
    totalUsage.output_tokens += result.usage.output_tokens;
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
