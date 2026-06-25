import { adminClient } from "../_shared/supabase.ts";
import { isUuid } from "../_shared/validate.ts";
import { redactQuestion } from "../_shared/quiz.ts";

export type QuizMode = "freehand" | "by_bucket" | "by_node";
export type QuizQuestionType = "mcq" | "short_answer" | "flashcard" | "mix";
type ConcreteQuestionType = "mcq" | "short_answer" | "flashcard";

export interface QuizConfigRow {
  id: string;
  user_id: string;
  mode: QuizMode;
  bucket_ids: string[] | null;
  node_ids: string[] | null;
  prompt: string | null;
  use_my_notes: boolean;
  question_count: number;
  question_type: QuizQuestionType;
  difficulty: number;
  timer_sec: number | null;
}

export interface ModelQuestion {
  type?: unknown;
  prompt?: unknown;
  options?: unknown;
  correct_index?: unknown;
  explanation?: unknown;
  reference_answer?: unknown;
  grading_rubric?: unknown;
  flashcard_back?: unknown;
  node_id?: unknown;
  source_node_ids?: unknown;
}

interface NodeMeta {
  nodeId: string;
  bucketId: string | null;
  bucketName: string | null;
}

const CONCRETE_TYPES: ConcreteQuestionType[] = ["mcq", "short_answer", "flashcard"];
const SECRET_FIELDS = new Set(["correct_index", "reference_answer", "grading_rubric", "flashcard_back"]);

function concreteType(questionType: QuizQuestionType, index: number, rawType: unknown): ConcreteQuestionType {
  if (questionType === "mix") return CONCRETE_TYPES[index % CONCRETE_TYPES.length];
  if (CONCRETE_TYPES.includes(questionType as ConcreteQuestionType)) return questionType as ConcreteQuestionType;
  if (CONCRETE_TYPES.includes(rawType as ConcreteQuestionType)) return rawType as ConcreteQuestionType;
  return "mcq";
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((v): v is string => typeof v === "string" && v.trim().length > 0);
}

function uuidArray(value: unknown): string[] {
  return stringArray(value).filter(isUuid);
}

export function redactedQuestion(questionJson: Record<string, unknown>, questionAttemptId: string) {
  return redactQuestion(questionJson, questionAttemptId);
}

async function loadNodeMeta(
  userId: string,
  nodeIds: string[],
  bucketIds: string[],
): Promise<Map<string, NodeMeta>> {
  const db = adminClient();
  const nodes = new Map<string, NodeMeta>();
  const ids = [...new Set(nodeIds.filter(Boolean))];

  if (ids.length) {
    const { data, error } = await db
      .from("nodes")
      .select("id, bucket_id, buckets!inner(id, name, user_id)")
      .in("id", ids)
      .is("deleted_at", null);
    if (error) throw error;

    for (const row of data ?? []) {
      const bucket = (row as { buckets?: { id?: string; name?: string; user_id?: string } }).buckets;
      if (bucket?.user_id !== userId) continue;
      const id = (row as { id: string }).id;
      nodes.set(id, {
        nodeId: id,
        bucketId: bucket.id ?? (row as { bucket_id?: string }).bucket_id ?? null,
        bucketName: bucket.name ?? null,
      });
    }
  }

  if (bucketIds.length) {
    const { data, error } = await db
      .from("buckets")
      .select("id, name, user_id")
      .in("id", [...new Set(bucketIds.filter(Boolean))])
      .is("deleted_at", null);
    if (error) throw error;
    for (const bucket of data ?? []) {
      if ((bucket as { user_id?: string }).user_id !== userId) continue;
      const id = (bucket as { id: string }).id;
      nodes.set(id, { nodeId: "", bucketId: id, bucketName: (bucket as { name?: string }).name ?? null });
    }
  }

  return nodes;
}

export async function resolveQuestionRows(
  config: QuizConfigRow,
  rawQuestions: ModelQuestion[],
  userId: string,
) {
  const selectedNodeIds = config.node_ids ?? [];
  const selectedBucketIds = config.bucket_ids ?? [];
  const generatedNodeIds = rawQuestions.flatMap((q) => [
    ...uuidArray(q.source_node_ids),
    ...(isUuid(stringOrNull(q.node_id)) ? [stringOrNull(q.node_id)!] : []),
  ]);
  const meta = await loadNodeMeta(userId, [...selectedNodeIds, ...generatedNodeIds], selectedBucketIds);
  const firstBucket = selectedBucketIds.map((id) => meta.get(id)).find(Boolean) ?? null;

  return rawQuestions.map((question, index) => {
    const type = concreteType(config.question_type, index, question.type);
    const sourceNodeIds = uuidArray(question.source_node_ids);
    const explicitNodeId = stringOrNull(question.node_id);
    const rawNodeId = explicitNodeId && isUuid(explicitNodeId) && meta.has(explicitNodeId)
      ? explicitNodeId
      : sourceNodeIds.find((id) => meta.has(id)) ?? null;
    const nodeMeta = rawNodeId ? meta.get(rawNodeId) : null;
    const bucketId = nodeMeta?.bucketId ?? firstBucket?.bucketId ?? null;
    const bucketName = nodeMeta?.bucketName ?? firstBucket?.bucketName ?? null;
    const options = Array.isArray(question.options)
      ? question.options.filter((v): v is string => typeof v === "string").slice(0, 4)
      : [];

    const questionJson: Record<string, unknown> = {
      position: index,
      type,
      prompt: stringOrNull(question.prompt) ?? "",
      difficulty: config.difficulty,
      source_node_ids: sourceNodeIds,
      node_id: rawNodeId,
      bucket_id: bucketId,
      bucket_name: bucketName,
      explanation: stringOrNull(question.explanation) ?? "",
    };

    if (type === "mcq") {
      questionJson.options = options;
      questionJson.correct_index = Number.isInteger(question.correct_index) ? question.correct_index : 0;
    } else if (type === "short_answer") {
      questionJson.reference_answer = stringOrNull(question.reference_answer) ?? "";
      questionJson.grading_rubric = stringOrNull(question.grading_rubric) ?? "";
    } else if (type === "flashcard") {
      questionJson.flashcard_back = stringOrNull(question.flashcard_back) ?? "";
    }

    for (const key of SECRET_FIELDS) {
      if (questionJson[key] == null) delete questionJson[key];
    }

    return {
      node_id: rawNodeId,
      bucket_id: bucketId,
      question_json: questionJson,
      position: index,
    };
  });
}
