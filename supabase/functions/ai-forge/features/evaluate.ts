// Feature: evaluate (AI overview, separate quota). Cache by content_hash; on a
// hit return the stored evaluation with no LLM call and no quota consumed.
// Empty text → 422. Otherwise consume an overview, evaluate, persist.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { stripHtml, truncate } from "../../_shared/text.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { gateConsume, assertAllowed, logUsage } from "../../_shared/quota.ts";
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
    .select("title, priority, difficulty, comfort, extracted_text, content_hash, buckets!inner(user_id, deleted_at)")
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
    content_hash?: string | null;
  };

  // Cache hit: latest evaluation matches the current content_hash.
  if (n.content_hash) {
    const { data: cached } = await db
      .from("node_ai_evaluations")
      .select("quality_score, suggested_comfort, suggested_difficulty, feedback, model, content_hash")
      .eq("node_id", nodeId)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (cached && (cached as { content_hash?: string }).content_hash === n.content_hash) {
      const c = cached as Record<string, unknown>;
      return {
        quality_score: c.quality_score,
        suggested_comfort: c.suggested_comfort,
        suggested_difficulty: c.suggested_difficulty,
        feedback: c.feedback,
        model: c.model,
        cached: true,
      };
    }
  }

  const text = stripHtml(n.extracted_text);
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

  const gen = await generateJson(config, tier, EVALUATE_SYSTEM, userPrompt);

  const quality = clampInt(gen.json.quality_score, 0, 100, 50);
  const comfort = clampInt(gen.json.suggested_comfort, 0, 100, n.comfort ?? 50);
  const difficulty = clampInt(gen.json.suggested_difficulty, 1, 5, n.difficulty ?? 3);
  const feedback = typeof gen.json.feedback === "string" ? gen.json.feedback : "";

  const { error: insErr } = await db.from("node_ai_evaluations").insert({
    node_id: nodeId,
    quality_score: quality,
    suggested_comfort: comfort,
    suggested_difficulty: difficulty,
    feedback,
    model: gen.model,
    content_hash: n.content_hash,
  });
  if (insErr) throw insErr;

  await logUsage(userId, "evaluate", gen.usage.input_tokens, gen.usage.output_tokens, gen.model);
  return {
    quality_score: quality,
    suggested_comfort: comfort,
    suggested_difficulty: difficulty,
    feedback,
    model: gen.model,
    cached: false,
  };
}
