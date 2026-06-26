// Feature: summarize. node scope = the node's corpus (no vector); bucket scope
// = concat for <=20 nodes, else RAG sample of ~2 chunks/node (with a corpus
// fallback). Uses nodeCorpusText so link/YouTube notes without extracted_text
// still summarize. Truly empty content → 422.

import { adminClient } from "../../_shared/supabase.ts";
import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { truncate } from "../../_shared/text.ts";
import { formatContext, RetrievedChunk } from "../../_shared/context.ts";
import { nodeCorpusText, NodeRow } from "../../_shared/node_corpus.ts";
import { openaiEmbed } from "../../_shared/providers/openai.ts";
import { generateJson, Tier } from "../../_shared/providers/route.ts";
import { gateConsume, assertAllowed, logUsage } from "../../_shared/quota.ts";
import { logInteraction } from "../../_shared/interactions.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { requireUuid } from "../../_shared/validate.ts";
import { SUMMARIZE_SYSTEM } from "../prompts.ts";

export async function summarize(payload: Record<string, unknown>, userId: string, config: AppConfig) {
  const scope = payload.scope === "node" ? "node" : payload.scope === "bucket" ? "bucket" : null;
  if (!scope) throw new AppError("invalid_input", "scope must be 'bucket' or 'node'");
  const db = adminClient();

  let contextText = "";
  let scopeName = "";

  if (scope === "node") {
    const nodeId = requireUuid(payload.node_id, "node_id");
    const { data: node } = await db
      .from("nodes")
      .select("title, extracted_text, markdown, url, link_preview_json, buckets!inner(user_id, deleted_at)")
      .eq("id", nodeId)
      .is("deleted_at", null)
      .maybeSingle();
    const owner = (node as { buckets?: { user_id?: string } } | null)?.buckets?.user_id;
    if (!node || owner !== userId) throw new AppError("invalid_input", "node not found");
    const n = node as NodeRow;
    const text = nodeCorpusText({ ...n, id: nodeId });
    if (!text) throw new AppError("empty_context");
    scopeName = n.title ?? "";
    contextText = `[Node: ${scopeName}]\n${truncate(text, config.int("ai_node_text_max_chars", 8000))}`;
  } else {
    const bucketId = requireUuid(payload.bucket_id, "bucket_id");
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
      // Large bucket: retrieve key chunks via RAG over a themes query.
      const embedModel = config.str("ai_model_embed", "text-embedding-3-small");
      const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
      const { embeddings } = await openaiEmbed(openaiKey, embedModel, [
        "key themes and facts in this bucket",
      ]);
      const { data: matches } = await db.rpc("match_chunks", {
        query_embedding: JSON.stringify(embeddings[0] ?? []),
        match_user_id: userId,
        match_count: maxNodes * 2,
        match_threshold: 0.0,
        filter_bucket_ids: [bucketId],
        filter_node_ids: null,
      });
      const rows = (matches ?? []) as { node_id: string; content: string; similarity: number }[];
      const titles = new Map<string, string>(
        withText.map((x: { node: NodeRow }) => [x.node.id, x.node.title ?? ""]),
      );
      const retrieved: RetrievedChunk[] = rows.map((r) => ({
        node_id: r.node_id,
        title: titles.get(r.node_id) ?? "",
        content: r.content,
        similarity: r.similarity,
      }));
      contextText = formatContext(retrieved, config.int("ai_context_max_chars", 12000)).text;
      // No embedded chunks yet → fall back to a corpus concat of the first nodes.
      if (!contextText) {
        const perNode = Math.floor(config.int("ai_context_max_chars", 12000) / maxNodes);
        contextText = withText
          .slice(0, maxNodes)
          .map((x: { node: NodeRow; corpus: string }) =>
            `[Node: ${x.node.title ?? ""}]\n${truncate(x.corpus, perNode)}`
          )
          .join("\n---\n");
      }
      if (!contextText) throw new AppError("empty_context");
    }
  }

  const decision = await gateConsume(userId, "summarize");
  assertAllowed(decision);
  const tier = (decision.tier ?? "free") as Tier;

  const userPrompt = `CONTEXT:\n${contextText}\n\nSCOPE: ${scope} — ${scopeName}`;
  const system = SUMMARIZE_SYSTEM + (await userDirectives(userId));
  const t0 = Date.now();
  const gen = await generateJson(config, tier, system, userPrompt);
  const latencyMs = Date.now() - t0;

  const summary = Array.isArray(gen.json.summary) ? (gen.json.summary as string[]).slice(0, 7) : [];
  const keyThemes = Array.isArray(gen.json.key_themes) ? (gen.json.key_themes as string[]).slice(0, 3) : [];

  await logUsage(userId, "summarize", gen.usage.input_tokens, gen.usage.output_tokens, gen.model);
  await logInteraction({
    userId,
    feature: "summarize",
    scope: { scope, node_id: payload.node_id ?? null, bucket_id: payload.bucket_id ?? null },
    hadNotes: true,
    blend: "notes_only",
    model: gen.model,
    latencyMs,
    inputTokens: gen.usage.input_tokens,
    outputTokens: gen.usage.output_tokens,
    payload: { context: contextText, summary, key_themes: keyThemes },
  });
  return { summary, key_themes: keyThemes, model: gen.model, usage: gen.usage };
}
