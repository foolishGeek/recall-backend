// Feature: suggest_prompts. Three short first-person starter questions for
// the Ask Aura empty state, scoped to a bucket (or the whole active set).
//
// Cached hard by content fingerprint — the model runs only when the scope's
// notes actually changed. Never touches the user's monthly AI quota.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { withMeteredRequest } from "../../_shared/quota.ts";
import { asUuidArray, requireUuid } from "../../_shared/validate.ts";
import { SUGGEST_PROMPTS_SYSTEM } from "../prompts.ts";

const FALLBACK_ACTIVE = [
  "What should I review first today?",
  "Summarize what I studied recently",
  "Which notes am I weakest on?",
];

export async function suggestPrompts(
  payload: Record<string, unknown>,
  userId: string,
  config: AppConfig,
) {
  const bucketIds = asUuidArray(payload.bucket_ids);
  const scopeKind = bucketIds?.length === 1 ? "bucket" : "active";
  const scopeId = scopeKind === "bucket" ? requireUuid(bucketIds![0], "bucket_ids[0]") : null;
  const db = adminClient();

  const { data: fingerprint, error: fpErr } = await db.rpc("ai_suggestions_fingerprint", {
    p_user: userId,
    p_scope_kind: scopeKind,
    p_scope_id: scopeId,
  });
  if (fpErr) throw fpErr;
  const fp = String(fingerprint ?? "");

  // Cache hit → return immediately, no model call, no ledger row.
  let cacheQ = db
    .from("ai_suggestions_cache")
    .select("suggestions, model")
    .eq("user_id", userId)
    .eq("scope_kind", scopeKind)
    .eq("fingerprint", fp)
    .limit(1);
  cacheQ = scopeId == null ? cacheQ.is("scope_id", null) : cacheQ.eq("scope_id", scopeId);
  const { data: cached } = await cacheQ.maybeSingle();
  if (cached?.suggestions) {
    const suggestions = asStringList(cached.suggestions);
    if (suggestions.length > 0) {
      return {
        suggestions,
        fingerprint: fp,
        cached: true,
        model: cached.model ?? null,
      };
    }
  }

  const meta = await loadScopeMeta(db, userId, scopeKind, scopeId);
  const templates = deterministicTemplates(meta);

  // Metered at zero cost (access=free). Still ledgered so daily cap is visible.
  // On any failure we settle failed and return templates — the empty state
  // must never break because the model hiccuped.
  try {
    return await withMeteredRequest(
      { userId, feature: "suggest_prompts" },
      async (reservation) => {
        const titles = meta.titles.slice(0, 15).map((t) => `- ${t}`).join("\n");
        const userPrompt = [
          `SCOPE: ${meta.label}`,
          meta.tags.length ? `TAGS: ${meta.tags.join(", ")}` : "",
          titles ? `RECENT NOTE TITLES:\n${titles}` : "RECENT NOTE TITLES: (none yet)",
          "",
          "Write three short first-person questions a student would ask about this material.",
        ].filter(Boolean).join("\n");

        const gen = await generateJson(
          config,
          reservation.tier as Tier,
          SUGGEST_PROMPTS_SYSTEM,
          userPrompt,
          {
            temperature: reservation.temperature,
            maxTokens: reservation.maxTokens ?? 256,
          },
        );

        let suggestions = asStringList(gen.json.suggestions);
        if (suggestions.length < 2) suggestions = templates;

        await db.rpc("ai_suggestions_cache_put", {
          p_user: userId,
          p_scope_kind: scopeKind,
          p_scope_id: scopeId,
          p_fingerprint: fp,
          p_suggestions: suggestions,
          p_model: gen.model,
        });

        return {
          result: {
            suggestions: suggestions.slice(0, 3),
            fingerprint: fp,
            cached: false,
            model: gen.model,
          },
          model: gen.model,
          inputTokens: gen.usage.input_tokens,
          outputTokens: gen.usage.output_tokens,
          cacheResponse: true,
        };
      },
    );
  } catch {
    return {
      suggestions: templates,
      fingerprint: fp,
      cached: false,
      model: null,
      fallback: true,
    };
  }
}

interface ScopeMeta {
  label: string;
  titles: string[];
  tags: string[];
}

async function loadScopeMeta(
  db: ReturnType<typeof adminClient>,
  userId: string,
  scopeKind: string,
  scopeId: string | null,
): Promise<ScopeMeta> {
  if (scopeKind === "bucket" && scopeId) {
    const { data: bucket } = await db
      .from("buckets")
      .select("name")
      .eq("id", scopeId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .maybeSingle();
    // A bucket id that is not this user's must not be described back to them,
    // and must not have its note titles read. This client is service-role, so
    // ownership is only enforced where we say it is. Reported as bad input
    // rather than "not found", which would confirm the bucket exists.
    if (!bucket) throw new AppError("invalid_input", "Unknown bucket.");
    const name = (bucket as { name?: string }).name ?? "this bucket";

    const { data: nodes } = await db
      .from("nodes")
      .select("id, title")
      .eq("bucket_id", scopeId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .order("updated_at", { ascending: false })
      .limit(15);
    const titles = (nodes ?? [])
      .map((n: { title?: string }) => (n.title ?? "").trim())
      .filter(Boolean);

    const ids = (nodes ?? []).map((n: { id: string }) => n.id);
    let tags: string[] = [];
    if (ids.length) {
      const { data: tagRows } = await db
        .from("node_tags")
        .select("tags(name)")
        .in("node_id", ids);
      tags = [...new Set(
        (tagRows ?? [])
          .map((r: { tags?: { name?: string } | { name?: string }[] | null }) => {
            const t = r.tags;
            if (Array.isArray(t)) return t[0]?.name ?? "";
            return t?.name ?? "";
          })
          .filter(Boolean),
      )];
    }
    return { label: name, titles, tags };
  }

  // The argument is `uid`. Calling it `p_user` made this RPC fail on every
  // request, and because the error was dropped the whole account-wide scope
  // silently resolved to "no buckets, no titles" — which is why every user saw
  // the same three generic starter questions.
  const { data: active, error: activeErr } = await db.rpc("active_buckets_for_user", {
    uid: userId,
  });
  if (activeErr) throw activeErr;
  const buckets = (active ?? []) as { id: string; name?: string }[];
  const ids = buckets.map((b) => b.id);
  const label = buckets.map((b) => b.name).filter(Boolean).slice(0, 3).join(", ") ||
    "my notes";

  let titles: string[] = [];
  if (ids.length) {
    const { data: nodes } = await db
      .from("nodes")
      .select("title")
      .in("bucket_id", ids)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .order("updated_at", { ascending: false })
      .limit(15);
    titles = (nodes ?? [])
      .map((n: { title?: string }) => (n.title ?? "").trim())
      .filter(Boolean);
  }
  return { label, titles, tags: [] };
}

function deterministicTemplates(meta: ScopeMeta): string[] {
  const name = meta.label.split(",")[0]?.trim() || "my notes";
  if (!meta.titles.length) {
    return [
      `What should I add to ${name}?`,
      ...FALLBACK_ACTIVE.slice(0, 2),
    ];
  }
  const first = meta.titles[0];
  return [
    `What are the key ideas in ${name}?`,
    `Quiz me on "${first}"`,
    `Summarize my recent notes in ${name}`,
  ];
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((v) => (typeof v === "string" ? v.trim() : ""))
    .filter((s) => s.length > 0)
    .slice(0, 5);
}
