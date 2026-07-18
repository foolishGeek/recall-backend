// Feature: evaluate (AI overview, separate quota). Cache by content_hash; on a
// hit return the stored evaluation with no LLM call and no quota consumed.
// Empty text → 422. Otherwise consume an overview, evaluate, persist.
// Standalone URL lines / link_suggestions are preserved so Apply never drops
// LINKED/WATCH cards.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { truncate } from "../../_shared/text.ts";
import { nodeCorpusText } from "../../_shared/node_corpus.ts";
import {
  collectNoteUrls,
  mergeStandaloneUrls,
  validateLinkSuggestions,
  type LinkSuggestion,
} from "../../_shared/note_links.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { gateConsume, assertAllowed, logUsage } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireUuid } from "../../_shared/validate.ts";
import { EVALUATE_SYSTEM } from "../prompts.ts";

function clampInt(v: unknown, lo: number, hi: number, fallback: number): number {
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(lo, Math.min(hi, Math.round(n)));
}

export async function evaluate(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const nodeId = requireUuid(payload.node_id, "node_id");
  const db = adminClient();

  const { data: node } = await db
    .from("nodes")
    .select("title, priority, difficulty, comfort, extracted_text, markdown, url, link_preview_json, content_hash, buckets!inner(user_id, deleted_at)")
    .eq("id", nodeId)
    .is("deleted_at", null)
    .maybeSingle();
  const owner = (node as { buckets?: { user_id?: string } } | null)?.buckets?.user_id;
  if (!node || owner !== userId) throw new AppError("invalid_input", "node not found");

  const n = node as {
    title?: string;
    priority?: number;
    difficulty?: number;
    comfort?: number;
    extracted_text?: string;
    markdown?: string | null;
    url?: string | null;
    link_preview_json?: Record<string, unknown>;
    content_hash?: string | null;
  };

  // Cache hit: latest evaluation matches the current content_hash.
  if (n.content_hash) {
    const { data: cached } = await db
      .from("node_ai_evaluations")
      .select(
        "quality_score, suggested_comfort, suggested_difficulty, feedback, suggested_markdown, link_suggestions, model, content_hash",
      )
      .eq("node_id", nodeId)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (cached && (cached as { content_hash?: string }).content_hash === n.content_hash) {
      const c = cached as Record<string, unknown>;
      // Defense: older cached rewrites may have dropped URL lines — re-merge
      // before returning so the client never applies a stripped body.
      const mergedCached = mergeStandaloneUrls(
        n.markdown,
        typeof c.suggested_markdown === "string" ? c.suggested_markdown : null,
      );
      return {
        quality_score: c.quality_score,
        suggested_comfort: c.suggested_comfort,
        suggested_difficulty: c.suggested_difficulty,
        feedback: c.feedback,
        suggested_markdown: mergedCached,
        link_suggestions: Array.isArray(c.link_suggestions) ? c.link_suggestions : [],
        model: c.model,
        cached: true,
        interaction_id: null,
      };
    }
  }

  const text = nodeCorpusText({
    id: nodeId,
    title: n.title,
    extracted_text: n.extracted_text,
    markdown: n.markdown,
    url: n.url,
    link_preview_json: n.link_preview_json,
  });
  if (!text) throw new AppError("empty_context");

  // Tags for the prompt.
  const { data: tagRows } = await db
    .from("node_tags")
    .select("tags(name)")
    .eq("node_id", nodeId);
  const tags = (tagRows ?? [])
    .map((r: { tags?: { name?: string } }) => r.tags?.name)
    .filter(Boolean)
    .join(", ");

  const decision = await gateConsume(userId, "evaluate");
  assertAllowed(decision);
  const tier = (decision.tier ?? "free") as Tier;

  const userPrompt = `NODE METADATA:
title: ${n.title ?? ""}
priority: ${n.priority ?? 3}
difficulty: ${n.difficulty ?? 3}
comfort_seed: ${n.comfort ?? 50}
tags: ${tags}

CONTENT:
${truncate(text, config.int("ai_node_text_max_chars", 8000))}`;

  const system = EVALUATE_SYSTEM + (await userDirectives(userId));
  const t0 = Date.now();
  const gen = await generateJson(config, tier, system, userPrompt);
  const latencyMs = Date.now() - t0;

  const quality = clampInt(gen.json.quality_score, 0, 100, 50);
  const comfort = clampInt(gen.json.suggested_comfort, 0, 100, n.comfort ?? 50);
  const difficulty = clampInt(gen.json.suggested_difficulty, 1, 5, n.difficulty ?? 3);
  const feedback = typeof gen.json.feedback === "string" ? gen.json.feedback : "";
  const rawMarkdown = typeof gen.json.suggested_markdown === "string"
    ? truncate(gen.json.suggested_markdown, config.int("ai_node_text_max_chars", 8000))
    : null;
  const suggestedMarkdown = mergeStandaloneUrls(n.markdown, rawMarkdown);

  const noteUrls = collectNoteUrls(n.markdown, n.url);
  const linkSuggestions: LinkSuggestion[] = validateLinkSuggestions(
    gen.json.link_suggestions,
    noteUrls,
    2,
  );

  const { error: insErr } = await db.from("node_ai_evaluations").insert({
    node_id: nodeId,
    quality_score: quality,
    suggested_comfort: comfort,
    suggested_difficulty: difficulty,
    feedback,
    suggested_markdown: suggestedMarkdown,
    link_suggestions: linkSuggestions,
    model: gen.model,
    content_hash: n.content_hash,
  });
  if (insErr) throw insErr;

  await logUsage(userId, "evaluate", gen.usage.input_tokens, gen.usage.output_tokens, gen.model);
  const interactionId = await logInteraction({
    userId,
    feature: "evaluate",
    scope: { node_id: nodeId },
    retrievedNodeIds: [nodeId],
    hadNotes: true,
    blend: "notes_only",
    model: gen.model,
    latencyMs,
    inputTokens: gen.usage.input_tokens,
    outputTokens: gen.usage.output_tokens,
    payload: {
      note: text,
      suggested_markdown: suggestedMarkdown,
      feedback,
      link_suggestions: linkSuggestions,
    },
    contentHash: n.content_hash ?? null,
  });
  return {
    quality_score: quality,
    suggested_comfort: comfort,
    suggested_difficulty: difficulty,
    feedback,
    suggested_markdown: suggestedMarkdown,
    link_suggestions: linkSuggestions,
    model: gen.model,
    cached: false,
    interaction_id: interactionId,
  };
}
