// Feature: summarize. node scope = the node's corpus (no vector); bucket scope
// = concat for <=20 nodes, else RAG sample of ~2 chunks/node (with a corpus
// fallback); asset scope = one attachment's extracted text. Uses nodeCorpusText
// so link/YouTube notes without extracted_text still summarize. Truly empty
// content → 422.

import { adminClient, rowAs } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { truncate } from "../../_shared/text.ts";
import { nodeCorpusText, NodeRow } from "../../_shared/node_corpus.ts";
import { retrieve, RetrieveResult } from "../../_shared/retrieve.ts";
import { captureRetrieval } from "../../_shared/retrieval_capture.ts";
import { registerPrompt } from "../../_shared/prompt_registry.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { withMeteredRequest } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireUuid } from "../../_shared/validate.ts";
import { shimScopeRequest } from "../../_shared/scope.ts";
import { SUMMARIZE_SYSTEM } from "../prompts.ts";

type SummarizeScope = "node" | "bucket" | "asset";

const SCOPE_KIND: Record<SummarizeScope, string> = {
  node: "nodes",
  bucket: "buckets",
  asset: "assets",
};

export async function summarize(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  // New descriptor: { scope: { kind: 'nodes'|'buckets'|'assets', ids: [...] } }.
  // Legacy: scope = 'node'|'bucket' plus node_id / bucket_id.
  const shimmed = shimScopeRequest(payload);
  let scope: SummarizeScope | null = null;
  let body = payload;
  if (shimmed.scope?.kind === "nodes" && shimmed.scope.ids.length === 1) {
    scope = "node";
    body = { ...payload, node_id: shimmed.scope.ids[0] };
  } else if (shimmed.scope?.kind === "buckets" && shimmed.scope.ids.length === 1) {
    scope = "bucket";
    body = { ...payload, bucket_id: shimmed.scope.ids[0] };
  } else if (shimmed.scope?.kind === "assets" && shimmed.scope.ids.length === 1) {
    scope = "asset";
    body = { ...payload, asset_id: shimmed.scope.ids[0] };
  } else if (payload.scope === "asset" || payload.asset_id) {
    scope = "asset";
  } else {
    scope = payload.scope === "node" ? "node" : payload.scope === "bucket" ? "bucket" : null;
  }
  if (!scope) throw new AppError("invalid_input", "scope must be 'bucket', 'node' or 'asset'");
  const db = adminClient();

  let contextText = "";
  let scopeName = "";
  let retrieved: RetrieveResult | null = null;

  if (scope === "asset") {
    const assetId = requireUuid(body.asset_id, "asset_id");
    const { data: asset } = await db
      .from("node_assets")
      .select("id, caption, extracted_text, nodes!inner(title, user_id)")
      .eq("id", assetId)
      .maybeSingle();
    const a = rowAs<{
      caption: string | null;
      extracted_text: string | null;
      nodes?: { title?: string | null; user_id?: string };
    }>(asset);
    if (!a || a.nodes?.user_id !== userId) throw new AppError("invalid_input", "attachment not found");
    const text = (a.extracted_text ?? "").trim();
    if (!text) throw new AppError("empty_context");
    scopeName = a.caption ?? a.nodes?.title ?? "";
    contextText = `[Attachment: ${scopeName}]\n${
      truncate(text, config.int("ai_node_text_max_chars", 8000))
    }`;
  } else if (scope === "node") {
    const nodeId = requireUuid(body.node_id, "node_id");
    const { data: node } = await db
      .from("nodes")
      .select("title, extracted_text, markdown, url, link_preview_json, user_id, buckets!inner(user_id, deleted_at)")
      .eq("id", nodeId)
      .is("deleted_at", null)
      .maybeSingle();
    const n = rowAs<NodeRow & { user_id?: string; buckets?: { user_id?: string } }>(node);
    const owner = n?.user_id ?? n?.buckets?.user_id;
    if (!n || owner !== userId) throw new AppError("invalid_input", "node not found");
    const text = nodeCorpusText({ ...n, id: nodeId });
    if (!text) throw new AppError("empty_context");
    scopeName = n.title ?? "";
    contextText = `[Node: ${scopeName}]\n${truncate(text, config.int("ai_node_text_max_chars", 8000))}`;
  } else {
    const bucketId = requireUuid(body.bucket_id, "bucket_id");
    const { data: bucket } = await db
      .from("buckets")
      .select("name, user_id")
      .eq("id", bucketId)
      .is("deleted_at", null)
      .maybeSingle();
    if (!bucket || (bucket as { user_id?: string }).user_id !== userId) {
      throw new AppError("invalid_input", "bucket not found");
    }
    scopeName = (bucket as { name?: string }).name ?? "";

    const { data: nodes } = await db
      .from("nodes")
      .select("id, title, extracted_text, markdown, url, link_preview_json")
      .eq("bucket_id", bucketId)
      .is("deleted_at", null);
    // Build a best-effort corpus per node so link/YouTube notes count too.
    const withText = (nodes ?? [])
      .map((n: NodeRow) => ({ node: n, corpus: nodeCorpusText(n) }))
      .filter((x: { corpus: string }) => x.corpus.length > 0);
    if (withText.length === 0) throw new AppError("empty_context");

    const maxNodes = config.int("ai_summarize_bucket_max_nodes", 20);
    if (withText.length <= maxNodes) {
      const perNode = Math.floor(config.int("ai_context_max_chars", 12000) / withText.length);
      contextText = withText
        .map((x: { node: NodeRow; corpus: string }) =>
          `[Node: ${x.node.title ?? ""}]\n${truncate(x.corpus, perNode)}`
        )
        .join("\n---\n");
    } else {
      // Large bucket: hybrid retrieve over a themes query, then format.
      retrieved = await retrieve(db, config, {
        feature: "summarize",
        userId,
        query: "key themes and facts in this bucket",
        bucketIds: [bucketId],
        nodeIds: null,
        topK: maxNodes * 2,
        threshold: config.num("ai_rag_summarize_similarity_threshold", 0.0),
      });
      contextText = retrieved.context.text;
      if (!contextText) throw new AppError("empty_context");
    }
  }

  const prompt = await registerPrompt("summarize", SUMMARIZE_SYSTEM);

  // Metered from here: the hold is released if the provider throws, so a failed
  // summary never spends one of the user's monthly requests.
  return withMeteredRequest({ userId, feature: "summarize" }, async (reservation) => {
    const tier = reservation.tier as Tier;
    const userPrompt = `CONTEXT:\n${contextText}\n\nSCOPE: ${scope} — ${scopeName}`;
    const system = SUMMARIZE_SYSTEM + (await userDirectives(userId));
    const t0 = Date.now();
    const gen = await generateJson(config, tier, system, userPrompt, {
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
    });
    const latencyMs = Date.now() - t0;

    const summary = Array.isArray(gen.json.summary) ? (gen.json.summary as string[]).slice(0, 7) : [];
    const keyThemes = Array.isArray(gen.json.key_themes) ? (gen.json.key_themes as string[]).slice(0, 3) : [];

    const scopeId = scope === "node"
      ? String(body.node_id)
      : scope === "asset"
      ? String(body.asset_id)
      : String(body.bucket_id);

    const interactionId = await logInteraction({
      userId,
      feature: "summarize",
      scope: {
        kind: SCOPE_KIND[scope],
        ids: [scopeId],
        scope,
        node_id: body.node_id ?? null,
        bucket_id: body.bucket_id ?? null,
        asset_id: body.asset_id ?? null,
      },
      hadNotes: true,
      blend: "notes_only",
      model: gen.model,
      provider: gen.provider,
      latencyMs,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
      requestId: reservation.requestId,
      promptId: prompt.promptId,
      systemPromptSha: prompt.sha,
      temperature: reservation.temperature,
      maxTokens: reservation.maxTokens,
      scopeKind: SCOPE_KIND[scope],
      retrievalMode: retrieved?.mode ?? "none",
      payload: { context: contextText, summary, key_themes: keyThemes },
    });

    await captureRetrieval(interactionId, retrieved);

    return {
      result: { summary, key_themes: keyThemes, model: gen.model, usage: gen.usage },
      model: gen.model,
      provider: gen.provider,
      inputTokens: gen.usage.input_tokens,
      outputTokens: gen.usage.output_tokens,
    };
  });
}
