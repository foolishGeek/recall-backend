// One retrieval path for every AI feature that needs notes.
//
// Pipeline: embed query → hybrid match (wide) → rerank seam → formatContext.
// On a miss (or when the embedder is down) fall back to a bounded corpus
// sample instead of dumping forty whole notes into the prompt.
//
// Scope-agnostic on purpose: buckets, specific notes, or specific attachments
// are all just filters passed to match_chunks_hybrid_v2, so a feature handler
// never has to know which kind it got.

import { SupabaseClient } from "./supabase.ts";
import { AppConfig } from "./config.ts";
import {
  formatContext,
  FormattedContext,
  RetrievedChunk,
} from "./context.ts";
import { embedQuery } from "./providers/embed.ts";
import { rerank } from "./rerank.ts";
import { nodeCorpusText, NodeRow } from "./node_corpus.ts";
import { truncate } from "./text.ts";

export type RetrievalFeature = "rag_chat" | "summarize" | "quiz_generate";
export type RetrievalMode = "hybrid" | "vector" | "corpus" | "none";

export interface RetrieveRequest {
  feature: RetrievalFeature;
  userId: string;
  query: string;
  bucketIds: string[] | null;
  nodeIds: string[] | null;
  /** Restrict to specific attachments (chunks with source_kind = 'asset'). */
  assetIds?: string[] | null;
  /** Restrict to a subset of source kinds, e.g. ["asset"] for "my PDFs only". */
  sourceKinds?: string[] | null;
  /** Override the formatted context budget. */
  maxChars?: number;
  /** Override top_k after rerank. */
  topK?: number;
  /** Override the similarity floor. */
  threshold?: number;
}

export interface RetrieveResult {
  context: FormattedContext;
  mode: RetrievalMode;
  /** Every candidate the hybrid (or corpus) step produced, before the trim. */
  candidates: RetrievedChunk[];
}

const THRESHOLD_KEYS: Record<RetrievalFeature, string> = {
  rag_chat: "ai_rag_chat_similarity_threshold",
  quiz_generate: "ai_rag_quiz_similarity_threshold",
  summarize: "ai_rag_summarize_similarity_threshold",
};

export async function retrieve(
  db: SupabaseClient,
  config: AppConfig,
  req: RetrieveRequest,
): Promise<RetrieveResult> {
  const maxChars = req.maxChars ?? config.int("ai_context_max_chars", 12000);
  const maxPerNode = config.int("ai_max_chunks_per_node", 3);
  const topK = req.topK ?? config.int("ai_rag_top_k", 8);
  const retrieveK = Math.max(topK, config.int("ai_rag_retrieve_k", 24));
  const threshold = req.threshold ??
    config.num(THRESHOLD_KEYS[req.feature], config.num("ai_rag_similarity_threshold", 0.55));

  const assetIds = req.assetIds?.length ? req.assetIds : null;
  // Asset-scoped requests only make sense against asset chunks.
  const sourceKinds = req.sourceKinds?.length
    ? req.sourceKinds
    : assetIds
    ? ["asset"]
    : null;

  if (!req.bucketIds?.length && !req.nodeIds?.length && !assetIds) {
    return empty("none");
  }

  const qEmbedding = await embedQuery(config, req.query);
  let candidates: RetrievedChunk[] = [];
  let mode: RetrievalMode = "none";

  if (qEmbedding || req.query.trim()) {
    // Postgres treats ANY('{}') as match-nothing. Empty arrays must become NULL
    // ("no filter"), or a node-only Ask AI silently gets zero hybrid hits and
    // falls back to a weaker corpus sample.
    const { data, error } = await db.rpc("match_chunks_hybrid_v2", {
      query_embedding: qEmbedding ? JSON.stringify(qEmbedding) : null,
      query_text: req.query,
      match_user_id: req.userId,
      match_count: retrieveK,
      match_threshold: threshold,
      filter_bucket_ids: req.bucketIds?.length ? req.bucketIds : null,
      filter_node_ids: req.nodeIds?.length ? req.nodeIds : null,
      filter_source_kinds: sourceKinds,
      filter_asset_ids: assetIds,
      embed_model: config.str("ai_model_embed", "text-embedding-3-small"),
      vector_candidate_count: retrieveK * 2,
      keyword_candidate_count: retrieveK * 2,
    });
    if (error) throw error;

    const rows = (data ?? []) as {
      node_id: string;
      chunk_id: string;
      content: string;
      similarity: number;
      vector_score: number;
      keyword_score: number;
      source_kind: string;
      source_id: string | null;
    }[];

    if (rows.length > 0) {
      const titles = await loadTitles(db, rows.map((r) => r.node_id));
      candidates = rows.map((r) => ({
        node_id: r.node_id,
        chunk_id: r.chunk_id,
        title: titles.get(r.node_id) ?? "",
        content: r.content,
        similarity: r.similarity,
        vector_score: r.vector_score,
        keyword_score: r.keyword_score,
        source_kind: r.source_kind ?? "node",
        source_id: r.source_id ?? null,
      }));
      // Keyword-only when the embedder was down but the query still ran; the
      // fusion is the same either way, so the mode name is too.
      mode = "hybrid";
    }
  }

  if (candidates.length === 0) {
    candidates = assetIds
      ? await assetFallback(db, config, req.userId, assetIds)
      : await corpusFallback(db, config, req);
    mode = candidates.length > 0 ? "corpus" : "none";
  }

  const trimmed = rerank({ query: req.query, candidates, topK });
  const context = formatContext(trimmed, { maxChars, maxChunksPerNode: maxPerNode });
  return { context, mode, candidates };
}

function empty(mode: RetrievalMode): RetrieveResult {
  return {
    context: { text: "", nodes: [], used: [] },
    mode,
    candidates: [],
  };
}

async function loadTitles(
  db: SupabaseClient,
  nodeIds: string[],
): Promise<Map<string, string>> {
  const ids = [...new Set(nodeIds)];
  if (ids.length === 0) return new Map();
  const { data } = await db.from("nodes").select("id, title").in("id", ids);
  return new Map(
    (data ?? []).map((n: { id: string; title: string }) => [n.id, n.title ?? ""]),
  );
}

/**
 * Attachments that have text but no chunks yet (OCR landed after the last
 * embed pass). Reads the extracted text directly so an asset-scoped question
 * is answerable the moment the text exists.
 */
async function assetFallback(
  db: SupabaseClient,
  config: AppConfig,
  userId: string,
  assetIds: string[],
): Promise<RetrievedChunk[]> {
  const maxChars = config.int("ai_corpus_fallback_max_chars", 8000);
  const { data, error } = await db
    .from("node_assets")
    .select("id, node_id, caption, extracted_text, nodes!inner(id, title, user_id)")
    .in("id", assetIds)
    .eq("nodes.user_id", userId)
    .not("extracted_text", "is", null);
  if (error) throw error;

  const rows = (data ?? []) as unknown as {
    id: string;
    node_id: string;
    caption: string | null;
    extracted_text: string | null;
    nodes: { title: string | null };
  }[];
  if (rows.length === 0) return [];

  const perAsset = Math.floor(maxChars / rows.length);
  return rows
    .filter((r) => (r.extracted_text ?? "").trim().length > 0)
    .map((r) => ({
      node_id: r.node_id,
      title: r.caption ?? r.nodes?.title ?? "",
      content: truncate(r.extracted_text ?? "", perAsset),
      similarity: 0.5,
      source_kind: "asset",
      source_id: r.id,
    }));
}

/**
 * Bounded corpus fallback. Prefer notes whose title shares a token with the
 * query; otherwise take a small recent sample. Always respect the character
 * budget so a miss never dumps the whole library into the prompt.
 */
async function corpusFallback(
  db: SupabaseClient,
  config: AppConfig,
  req: RetrieveRequest,
): Promise<RetrievedChunk[]> {
  const maxNodes = config.int("ai_corpus_fallback_max_nodes", 12);
  const maxChars = config.int("ai_corpus_fallback_max_chars", 8000);

  let q = db
    .from("nodes")
    .select("id, title, extracted_text, markdown, url, link_preview_json, bucket_id, updated_at")
    // This client is service-role and bypasses RLS, so ownership is not implied
    // by anything above. Without it, one bad id in the scope would read another
    // user's notes into the prompt.
    .eq("user_id", req.userId)
    .is("deleted_at", null)
    .order("updated_at", { ascending: false })
    .limit(Math.max(maxNodes * 3, maxNodes));

  if (req.bucketIds?.length) q = q.in("bucket_id", req.bucketIds);
  if (req.nodeIds?.length) q = q.in("id", req.nodeIds);

  const { data, error } = await q;
  if (error) throw error;

  const rows = (data ?? []) as (NodeRow & { updated_at?: string })[];
  if (rows.length === 0) return [];

  const tokens = queryTokens(req.query);
  const scored = rows.map((n) => {
    const title = (n.title ?? "").toLowerCase();
    let score = 0;
    for (const t of tokens) if (title.includes(t)) score += 1;
    return { node: n, score };
  });
  scored.sort((a, b) => b.score - a.score || 0);

  const picked = scored.slice(0, maxNodes);
  const perNode = Math.floor(maxChars / Math.max(picked.length, 1));
  const out: RetrievedChunk[] = [];
  for (const { node, score } of picked) {
    const content = nodeCorpusText(node);
    if (!content) continue;
    out.push({
      node_id: node.id,
      title: node.title ?? "",
      content: truncate(content, perNode),
      // Title hits rank above recent-but-unrelated notes.
      similarity: score > 0 ? 0.5 + Math.min(0.4, score * 0.1) : 0.2,
      source_kind: "node",
      source_id: node.id,
    });
  }
  return out;
}

function queryTokens(query: string): string[] {
  return query
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .map((t) => t.trim())
    .filter((t) => t.length >= 3)
    .slice(0, 12);
}
