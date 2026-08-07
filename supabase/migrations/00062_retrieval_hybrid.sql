-- Phase 4: hybrid retrieval (keyword + vector) and retuned RAG knobs.
--
-- Vector-only search is weak on proper nouns, rare terms, and code identifiers.
-- A tsvector on each chunk plus reciprocal-rank fusion with the existing
-- embedding search fixes that without a second index service.
--
-- match_chunks stays as a thin wrapper so older callers keep working; new code
-- should call match_chunks_hybrid.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Keyword index on chunks
-- ---------------------------------------------------------------------

ALTER TABLE node_chunks
  ADD COLUMN IF NOT EXISTS content_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      coalesce(context_header, '') || ' ' || coalesce(content, '')
    )
  ) STORED;

CREATE INDEX IF NOT EXISTS idx_node_chunks_content_tsv
  ON node_chunks USING gin (content_tsv);

-- ---------------------------------------------------------------------
-- Hybrid match: retrieve wide from each channel, fuse with RRF
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
  WITH scoped AS (
    SELECT nc.id, nc.node_id, nc.content, nc.embedding, nc.content_tsv
    FROM node_chunks nc
    JOIN nodes n ON n.id = nc.node_id
    JOIN buckets b ON b.id = n.bucket_id
    WHERE (auth.uid() = match_user_id OR auth.role() = 'service_role')
      AND b.user_id = match_user_id
      AND n.deleted_at IS NULL
      AND b.deleted_at IS NULL
      AND (filter_bucket_ids IS NULL OR b.id = ANY(filter_bucket_ids))
      AND (filter_node_ids IS NULL OR n.id = ANY(filter_node_ids))
  ),
  vector_hits AS (
    SELECT
      s.id AS chunk_id,
      s.node_id,
      s.content,
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
    -- Expose a single "similarity" so callers that only read that column still
    -- sort correctly. Prefer the vector score when present; otherwise scale the
    -- keyword rank into (0,1] via the fused RRF value.
    CASE
      WHEN f.vector_score > 0 THEN f.vector_score
      ELSE least(1.0, f.rrf * 30)
    END AS similarity,
    f.vector_score,
    f.keyword_score
  FROM fused f
  ORDER BY f.rrf DESC, f.vector_score DESC, f.keyword_score DESC
  LIMIT match_count;
$$;

REVOKE ALL ON FUNCTION match_chunks_hybrid(
  vector(1536), text, uuid, int, float, uuid[], uuid[], int, int
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION match_chunks_hybrid(
  vector(1536), text, uuid, int, float, uuid[], uuid[], int, int
) TO authenticated, service_role;

-- Keep the old signature as a vector-only wrapper so existing callers do not
-- break while they migrate to the hybrid path.
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
    NULL,                 -- keyword channel off
    match_user_id,
    match_count,
    match_threshold,
    filter_bucket_ids,
    filter_node_ids,
    match_count * 4,
    0
  ) h;
$$;

-- ---------------------------------------------------------------------
-- Retrieval knobs (retuned now that chunks carry title context)
-- ---------------------------------------------------------------------

INSERT INTO app_config (key, value) VALUES
  -- How many chunks from one note may reach the model.
  ('ai_max_chunks_per_node', '3'::jsonb),
  -- Retrieve this many before the (currently no-op) rerank trims to top_k.
  ('ai_rag_retrieve_k', '24'::jsonb),
  -- Per-feature similarity floors. Chat was 0.7 against title-less chunks;
  -- with contextual headers a lower floor recovers rare-term hits.
  ('ai_rag_chat_similarity_threshold', '0.55'::jsonb),
  ('ai_rag_quiz_similarity_threshold', '0.55'::jsonb),
  ('ai_rag_summarize_similarity_threshold', '0.0'::jsonb),
  -- Corpus fallback budget: relevance + character cap, not "dump 40 notes".
  ('ai_corpus_fallback_max_nodes', '12'::jsonb),
  ('ai_corpus_fallback_max_chars', '8000'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- Soft-retune the legacy global key so any still-reading caller moves with us.
UPDATE app_config
SET value = '0.55'::jsonb, updated_at = now()
WHERE key = 'ai_rag_similarity_threshold'
  AND (value #>> '{}')::numeric >= 0.7;
