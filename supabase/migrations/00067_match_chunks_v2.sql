-- Phase 7: hybrid retrieval keyed on node_chunks.user_id, with optional
-- source-kind / asset filters and a model-aware embedding lookup.
--
-- Prefer chunk_embeddings for the requested model; fall back to the inline
-- node_chunks.embedding so pre-split rows still match. Existing match_chunks
-- and match_chunks_hybrid keep their 00062 signatures as thin wrappers.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION match_chunks_hybrid_v2(
  query_embedding vector(1536),
  query_text text,
  match_user_id uuid,
  match_count int DEFAULT 8,
  match_threshold float DEFAULT 0.55,
  filter_bucket_ids uuid[] DEFAULT NULL,
  filter_node_ids uuid[] DEFAULT NULL,
  filter_source_kinds text[] DEFAULT NULL,
  filter_asset_ids uuid[] DEFAULT NULL,
  embed_model text DEFAULT 'text-embedding-3-small',
  vector_candidate_count int DEFAULT 40,
  keyword_candidate_count int DEFAULT 40
)
RETURNS TABLE (
  node_id uuid,
  chunk_id uuid,
  content text,
  similarity float,
  vector_score float,
  keyword_score float,
  source_kind text,
  source_id uuid
)
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  WITH scoped AS (
    SELECT
      nc.id,
      nc.node_id,
      nc.content,
      nc.content_tsv,
      nc.source_kind,
      nc.source_id,
      -- Model-specific vector first; inline column is the legacy fallback.
      COALESCE(ce.embedding, nc.embedding) AS embedding
    FROM node_chunks nc
    JOIN nodes n ON n.id = nc.node_id
    LEFT JOIN chunk_embeddings ce
      ON ce.chunk_id = nc.id
     AND ce.model = COALESCE(embed_model, 'text-embedding-3-small')
    WHERE (auth.uid() = match_user_id OR auth.role() = 'service_role')
      AND COALESCE(nc.user_id, n.user_id) = match_user_id
      AND n.deleted_at IS NULL
      AND n.user_id = match_user_id
      AND (filter_bucket_ids IS NULL OR n.bucket_id = ANY(filter_bucket_ids))
      AND (filter_node_ids IS NULL OR n.id = ANY(filter_node_ids))
      AND (filter_source_kinds IS NULL OR nc.source_kind = ANY(filter_source_kinds))
      AND (
        filter_asset_ids IS NULL
        OR (nc.source_kind = 'asset' AND nc.source_id = ANY(filter_asset_ids))
      )
  ),
  vector_hits AS (
    SELECT
      s.id AS chunk_id,
      s.node_id,
      s.content,
      s.source_kind,
      s.source_id,
      1 - (s.embedding <=> query_embedding) AS vector_score,
      row_number() OVER (ORDER BY s.embedding <=> query_embedding) AS rank
    FROM scoped s
    WHERE query_embedding IS NOT NULL
      AND s.embedding IS NOT NULL
      AND 1 - (s.embedding <=> query_embedding) > match_threshold
    ORDER BY s.embedding <=> query_embedding
    LIMIT greatest(vector_candidate_count, match_count)
  ),
  keyword_hits AS (
    SELECT
      s.id AS chunk_id,
      s.node_id,
      s.content,
      s.source_kind,
      s.source_id,
      ts_rank_cd(s.content_tsv, websearch_to_tsquery('english', query_text)) AS keyword_score,
      row_number() OVER (
        ORDER BY ts_rank_cd(s.content_tsv, websearch_to_tsquery('english', query_text)) DESC
      ) AS rank
    FROM scoped s
    WHERE coalesce(nullif(btrim(query_text), ''), '') <> ''
      AND s.content_tsv @@ websearch_to_tsquery('english', query_text)
    ORDER BY keyword_score DESC
    LIMIT greatest(keyword_candidate_count, match_count)
  ),
  fused AS (
    SELECT
      coalesce(v.chunk_id, k.chunk_id) AS chunk_id,
      coalesce(v.node_id, k.node_id) AS node_id,
      coalesce(v.content, k.content) AS content,
      coalesce(v.source_kind, k.source_kind) AS source_kind,
      coalesce(v.source_id, k.source_id) AS source_id,
      coalesce(v.vector_score, 0)::float AS vector_score,
      coalesce(k.keyword_score, 0)::float AS keyword_score,
      coalesce(1.0 / (60 + v.rank), 0) + coalesce(1.0 / (60 + k.rank), 0) AS rrf
    FROM vector_hits v
    FULL OUTER JOIN keyword_hits k ON k.chunk_id = v.chunk_id
  )
  SELECT
    f.node_id,
    f.chunk_id,
    f.content,
    CASE
      WHEN f.vector_score > 0 THEN f.vector_score
      ELSE least(1.0, f.rrf * 30)
    END AS similarity,
    f.vector_score,
    f.keyword_score,
    f.source_kind,
    f.source_id
  FROM fused f
  ORDER BY f.rrf DESC, f.vector_score DESC, f.keyword_score DESC
  LIMIT match_count;
$$;

REVOKE ALL ON FUNCTION match_chunks_hybrid_v2(
  vector(1536), text, uuid, int, float, uuid[], uuid[], text[], uuid[], text, int, int
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION match_chunks_hybrid_v2(
  vector(1536), text, uuid, int, float, uuid[], uuid[], text[], uuid[], text, int, int
) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Back-compat wrappers (same signatures as 00062)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION match_chunks_hybrid(
  query_embedding vector(1536),
  query_text text,
  match_user_id uuid,
  match_count int DEFAULT 8,
  match_threshold float DEFAULT 0.55,
  filter_bucket_ids uuid[] DEFAULT NULL,
  filter_node_ids uuid[] DEFAULT NULL,
  vector_candidate_count int DEFAULT 40,
  keyword_candidate_count int DEFAULT 40
)
RETURNS TABLE (
  node_id uuid,
  chunk_id uuid,
  content text,
  similarity float,
  vector_score float,
  keyword_score float
)
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT
    h.node_id, h.chunk_id, h.content, h.similarity, h.vector_score, h.keyword_score
  FROM match_chunks_hybrid_v2(
    query_embedding,
    query_text,
    match_user_id,
    match_count,
    match_threshold,
    filter_bucket_ids,
    filter_node_ids,
    NULL,   -- all source kinds
    NULL,   -- no asset filter
    'text-embedding-3-small',
    vector_candidate_count,
    keyword_candidate_count
  ) h;
$$;

REVOKE ALL ON FUNCTION match_chunks_hybrid(
  vector(1536), text, uuid, int, float, uuid[], uuid[], int, int
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION match_chunks_hybrid(
  vector(1536), text, uuid, int, float, uuid[], uuid[], int, int
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION match_chunks(
  query_embedding vector(1536),
  match_user_id uuid,
  match_count int DEFAULT 8,
  match_threshold float DEFAULT 0.7,
  filter_bucket_ids uuid[] DEFAULT NULL,
  filter_node_ids uuid[] DEFAULT NULL
)
RETURNS TABLE (node_id uuid, chunk_id uuid, content text, similarity float)
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT h.node_id, h.chunk_id, h.content, h.similarity
  FROM match_chunks_hybrid(
    query_embedding,
    NULL,
    match_user_id,
    match_count,
    match_threshold,
    filter_bucket_ids,
    filter_node_ids,
    match_count * 4,
    0
  ) h;
$$;

REVOKE ALL ON FUNCTION match_chunks(
  vector(1536), uuid, int, float, uuid[], uuid[]
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION match_chunks(
  vector(1536), uuid, int, float, uuid[], uuid[]
) TO authenticated, service_role;
