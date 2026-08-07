// Feature: quiz_generate (internal — called by the quiz-generate EF in S17).
// Assembles context by mode and asks the model for question_count questions.
// The full server-side question_json superset [D-QUIZ-1] is owned by S17; here
// we return the raw model questions.
//
// [D-AI-7] freehand is topic-aware: it derives the collective topics of the
// selected scope (titles + tags), retrieves notes (with a corpus fallback),
// optionally blends web context (no-op hook), and lets the model add broader
// general-knowledge questions on the same topics. by_node/by_bucket use the
// node corpus so link/YouTube notes without extracted_text still produce a quiz.

import { adminClient, rowsAs } from "../../_shared/supabase.ts";
import { resolveScope } from "../../_shared/scope.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { truncate } from "../../_shared/text.ts";
import { nodeCorpusText, NodeRow } from "../../_shared/node_corpus.ts";
import { retrieve, RetrieveResult } from "../../_shared/retrieve.ts";
import { captureRetrieval } from "../../_shared/retrieval_capture.ts";
import { registerPrompt } from "../../_shared/prompt_registry.ts";
import { generateQuizQuestions, normalizeQuestions } from "../quiz_json.ts";
import { withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { webContext } from "../../_shared/web_context.ts";
import { asUuidArray } from "../../_shared/validate.ts";
import { quizGenerateSystem } from "../prompts.ts";

const CORPUS_FIELDS = "id, title, extracted_text, markdown, url, link_preview_json, bucket_id";

function typeLabel(questionType: string): string {
  switch (questionType) {
    case "short_answer":
      return "short answer";
    case "flashcard":
      return "flashcard";
    case "mix":
      return "mix (mcq → short answer → flashcard, repeating)";
    default:
      return "multiple choice";
  }
}

export async function quizGenerate(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const mode = ["freehand", "by_bucket", "by_node"].includes(payload.mode as string)
    ? (payload.mode as string)
    : "freehand";
  const questionCount = Math.max(1, Math.min(50, Number(payload.question_count) || 10));
  const difficulty = Math.max(1, Math.min(5, Number(payload.difficulty) || 3));
  const questionType = ["mcq", "short_answer", "flashcard", "mix"].includes(payload.question_type as string)
    ? (payload.question_type as string)
    : "mcq";
  const prompt = typeof payload.prompt === "string" ? payload.prompt : "";
  const useMyNotes = payload.use_my_notes !== false;
  const requestedBuckets = asUuidArray(payload.bucket_ids);
  const requestedNodes = asUuidArray(payload.node_ids);
  const db = adminClient();

  const maxChars = config.int("ai_context_max_chars", 12000);
  let context = "";
  let topics = "";
  const retrievedNodeIds = new Set<string>();
  let scopeLabel = "";
  let retrieved: RetrieveResult | null = null;
  const sourceNodeTitles: string[] = [];

  const corpusBlocks = (rows: NodeRow[]): string => {
    const per = Math.floor(maxChars / Math.max(rows.length, 1));
    return rows
      .map((n) => {
        const text = nodeCorpusText(n);
        if (text) {
          retrievedNodeIds.add(n.id);
          const title = (n.title ?? "").trim() || "Untitled note";
          sourceNodeTitles.push(title);
        }
        return text ? `[Node: ${n.title ?? ""} | id:${n.id}]\n${truncate(text, per)}` : "";
      })
      .filter((b) => b.length > 0)
      .join("\n---\n");
  };

  if (mode === "by_node") {
    const nodeIds = requestedNodes ?? [];
    if (nodeIds.length) {
      const { data: nodes } = await db
        .from("nodes")
        .select(`${CORPUS_FIELDS}, buckets!inner(user_id, name)`)
        .in("id", nodeIds)
        .is("deleted_at", null);
      const rows = rowsAs<NodeRow & { buckets?: { user_id?: string; name?: string } }>(nodes);
      const owned = rows.filter((n) => n.buckets?.user_id === userId);
      context = corpusBlocks(owned);
      const bucketNames = [
        ...new Set(rows.map((n) => n.buckets?.name ?? "").filter(Boolean)),
      ];
      scopeLabel = sourceNodeTitles.length
        ? `notes: ${sourceNodeTitles.join(", ")}`
        : `${nodeIds.length} selected note(s)`;
      if (bucketNames.length) scopeLabel += ` (buckets: ${bucketNames.join(", ")})`;
    }
  } else if (mode === "by_bucket") {
    const bucketIds = requestedBuckets ?? [];
    if (bucketIds.length) {
      const { data: bucketRows } = await db
        .from("buckets")
        .select("id, name")
        .in("id", bucketIds)
        .is("deleted_at", null);
      const bucketNames = (bucketRows ?? []).map((b: { name?: string }) => b.name ?? "").filter(Boolean);
      scopeLabel = bucketNames.length
        ? `buckets: ${bucketNames.join(", ")}`
        : `${bucketIds.length} bucket(s)`;

      // Due-first sample: earliest due nodes first (user priority via due_at).
      const { data: nodes } = await db
        .from("nodes")
        .select(`${CORPUS_FIELDS}, comfort, due_at, priority, buckets!inner(user_id)`)
        .in("bucket_id", bucketIds)
        .is("deleted_at", null)
        .order("due_at", { ascending: true, nullsFirst: false })
        .order("priority", { ascending: false })
        .limit(questionCount * 2);
      const owned = rowsAs<NodeRow & { buckets?: { user_id?: string } }>(nodes)
        .filter((n) => n.buckets?.user_id === userId);
      context = corpusBlocks(owned);
    }
  } else {
    // freehand — derive collective topics from the chosen scope, then RAG.
    const scope = await resolveScope(db, userId, {
      bucketIds: requestedBuckets?.length ? requestedBuckets : null,
      nodeIds: requestedNodes,
    });
    const scopeIds = scope.bucketIds;

    if (useMyNotes && scopeIds.length) {
      // Collective topics: titles + tags across the scope (capped).
      let topicQ = db
        .from("nodes")
        .select("id, title")
        .in("bucket_id", scopeIds)
        .is("deleted_at", null)
        .limit(40);
      if (requestedNodes?.length) topicQ = topicQ.in("id", requestedNodes);
      const { data: topicNodes } = await topicQ;
      const titles = [...new Set((topicNodes ?? []).map((n: { title?: string }) => (n.title ?? "").trim()).filter(Boolean))];
      const ids = (topicNodes ?? []).map((n: { id: string }) => n.id);
      let tagNames: string[] = [];
      if (ids.length) {
        const { data: tagRows } = await db.from("node_tags").select("tags(name)").in("node_id", ids);
        tagNames = [...new Set(
          rowsAs<{ tags?: { name?: string } | null }>(tagRows)
            .map((r) => r.tags?.name ?? "")
            .filter(Boolean),
        )];
      }
      topics = [...titles.slice(0, 12), ...tagNames.slice(0, 8)].join(", ");

      // Hybrid retrieve over the scope using the prompt + collective topics.
      const query = [prompt, topics].filter(Boolean).join(". ") || "key themes";
      retrieved = await retrieve(db, config, {
        feature: "quiz_generate",
        userId,
        query,
        bucketIds: scopeIds,
        nodeIds: scope.nodeIds,
        assetIds: scope.assetIds,
      });
      if (retrieved.context.text) {
        for (const n of retrieved.context.nodes) retrievedNodeIds.add(n.node_id);
        context = retrieved.context.text;
      }
    }

    // Web grounding hook (no-op today) — merged into context when enabled.
    const web = await webContext([prompt, topics].filter(Boolean).join(". "), config);
    if (web.text) context = [context, `[Web]\n${web.text}`].filter(Boolean).join("\n---\n");
    if (requestedBuckets?.length) {
      const { data: bucketRows } = await db
        .from("buckets")
        .select("name")
        .in("id", requestedBuckets)
        .is("deleted_at", null);
      const names = (bucketRows ?? []).map((b: { name?: string }) => b.name ?? "").filter(Boolean);
      if (names.length) scopeLabel = `buckets: ${names.join(", ")}`;
    } else if (useMyNotes) {
      scopeLabel = "all active buckets";
    }
  }

  if ((mode === "by_bucket" || mode === "by_node") && !context.trim()) {
    throw new AppError(
      "empty_context",
      "Selected notes have no readable content yet. Add text to your notes and try again.",
    );
  }

  // A generation that yields no usable questions throws below, which releases
  // the hold — the user is never charged for a quiz they did not receive.
  return withMeteredRequest({ userId, feature: "quiz_generate" }, async (reservation) => {
    const baseSystem = quizGenerateSystem(questionCount, difficulty, questionType);
    const promptRef = await registerPrompt("quiz_generate", baseSystem);
    const system = baseSystem + (await userDirectives(userId));
    const modeLine = `MODE: ${mode}${scopeLabel ? ` · ${scopeLabel}` : ""}`;
    const notesLine = useMyNotes || mode !== "freehand"
      ? `Ground questions in CONTEXT below. Every question must reflect the selected notes/buckets when content is present.`
      : `CONTEXT is optional; lean on the USER PROMPT and general knowledge.`;
    const userPrompt = `${modeLine}
${notesLine}
TOPICS: ${topics || "(from prompt and notes)"}
QUESTION FORMAT: ${typeLabel(questionType)} · exactly ${questionCount} questions · difficulty ${difficulty}/5

CONTEXT:
${context || "(no notes provided)"}

USER PROMPT${mode === "freehand" ? "" : " (ignored for this mode)"}: ${prompt || "(none)"}

Generate ${questionCount} questions. Respect the requested format above.`;
    const t0 = Date.now();
    const gen = await generateQuizQuestions({
      config,
      system,
      userPrompt,
      questionCount,
      questionType,
      temperature: reservation.temperature,
    });
    const latencyMs = Date.now() - t0;

    const questions = normalizeQuestions({ questions: gen.questions });
    if (!questions.length) {
      throw new AppError(
        "provider_error",
        "No quiz questions were generated. Try fewer questions or add more note content.",
      );
    }

    const hadNotes = context.length > 0;
    const interactionId = await logInteraction({
      userId,
      feature: "quiz_generate",
      scope: { mode, bucket_ids: requestedBuckets ?? null, node_ids: requestedNodes ?? null, topics },
      retrievedNodeIds: [...retrievedNodeIds],
      hadNotes,
      blend: hadNotes ? "blended" : "general_only",
      model: gen.model,
      latencyMs,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      requestId: reservation.requestId,
      promptId: promptRef.promptId,
      systemPromptSha: promptRef.sha,
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
      scopeKind: mode === "by_node" ? "nodes" : mode === "by_bucket" ? "buckets" : "active_buckets",
      retrievalMode: retrieved?.mode ?? "none",
      payload: { prompt, topics, context, question_count: questionCount, question_type: questionType },
    });

    await captureRetrieval(interactionId, retrieved);

    return {
      result: { questions, model: gen.model, usage: gen.usage },
      model: gen.model,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
    };
  });
}
