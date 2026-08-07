-- Phase 7: split chunk text from vectors so multiple embed models can index
-- the same chunks (A/B before switching off OpenAI).
--
-- node_chunks keeps the inline embedding column for back-compat; new writes
-- dual-write into chunk_embeddings. Retrieval v2 prefers the model-specific
-- row and falls back to the inline vector.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- node_chunks: provenance + owner denorm
-- ---------------------------------------------------------------------

ALTER TABLE node_chunks
  ADD COLUMN IF NOT EXISTS source_kind text NOT NULL DEFAULT 'node',
  ADD COLUMN IF NOT EXISTS source_id uuid,
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS content_sha text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'node_chunks_source_kind_chk'
  ) THEN
    ALTER TABLE node_chunks
      ADD CONSTRAINT node_chunks_source_kind_chk
      CHECK (source_kind IN ('node', 'asset'));
  END IF;
END $$;

COMMENT ON COLUMN node_chunks.source_kind IS
  'What produced this chunk: node body or an attached asset.';
COMMENT ON COLUMN node_chunks.source_id IS
  'Id of the source (node_id or node_assets.id). Defaults to node_id for legacy rows.';
COMMENT ON COLUMN node_chunks.user_id IS
  'Owner denormalised from nodes.user_id for retrieval without a buckets join.';
COMMENT ON COLUMN node_chunks.content_sha IS
  'SHA of the embedded text (header+content) so re-embed can skip unchanged chunks.';

-- Backfill owner + source_id from the parent node.
UPDATE node_chunks nc
SET user_id = n.user_id,
    source_id = COALESCE(nc.source_id, nc.node_id),
    source_kind = COALESCE(nc.source_kind, 'node')
FROM nodes n
WHERE n.id = nc.node_id
  AND (nc.user_id IS NULL OR nc.source_id IS NULL);

-- ---------------------------------------------------------------------
-- chunk_embeddings: one vector per (chunk, model)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS chunk_embeddings (
  chunk_id  uuid NOT NULL REFERENCES node_chunks(id) ON DELETE CASCADE,
  model     text NOT NULL,
  dim       integer NOT NULL,
  embedding vector(1536) NOT NULL,
  PRIMARY KEY (chunk_id, model)
);

COMMENT ON TABLE chunk_embeddings IS
  'Model-keyed vectors for node_chunks. Multiple models may index the same chunk for A/B.';

CREATE INDEX IF NOT EXISTS idx_chunk_embeddings_model
  ON chunk_embeddings (model);

DO $$
BEGIN
  BEGIN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_chunk_embeddings_hnsw
               ON chunk_embeddings USING hnsw (embedding vector_cosine_ops)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'HNSW unavailable for chunk_embeddings, falling back to ivfflat: %', SQLERRM;
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_chunk_embeddings_ivfflat
               ON chunk_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
  END;
END $$;

ALTER TABLE chunk_embeddings ENABLE ROW LEVEL SECURITY;

-- Owner read via the parent chunk's node.
DROP POLICY IF EXISTS chunk_embeddings_select_owner ON chunk_embeddings;
CREATE POLICY chunk_embeddings_select_owner ON chunk_embeddings
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM node_chunks nc
      WHERE nc.id = chunk_id AND owns_node(nc.node_id)
    )
  );

-- Dual-write existing inline embeddings into the new table.
INSERT INTO chunk_embeddings (chunk_id, model, dim, embedding)
SELECT nc.id, 'text-embedding-3-small', 1536, nc.embedding
FROM node_chunks nc
WHERE nc.embedding IS NOT NULL
ON CONFLICT (chunk_id, model) DO NOTHING;

-- ---------------------------------------------------------------------
-- Atomic replace: still writes inline embedding + chunk_embeddings
-- ---------------------------------------------------------------------

-- p_chunks: [{ chunk_index, content, context_header, token_count, embedding,
--              source_kind?, source_id?, content_sha?, embed_model? }]
CREATE OR REPLACE FUNCTION node_chunks_replace(p_node_id uuid, p_chunks jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_count   integer;
  v_user_id uuid;
  v_model   text := 'text-embedding-3-small';
BEGIN
  IF p_chunks IS NULL OR jsonb_typeof(p_chunks) <> 'array' THEN
    RAISE EXCEPTION 'node_chunks_replace: p_chunks must be a JSON array';
  END IF;

  SELECT user_id INTO v_user_id FROM nodes WHERE id = p_node_id;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'node_chunks_replace: node % not found or missing user_id', p_node_id;
  END IF;

  -- Optional per-call model override on the first element; default matches
  -- today's OpenAI small embedder.
  IF jsonb_array_length(p_chunks) > 0 THEN
    v_model := COALESCE(
      nullif(p_chunks->0->>'embed_model', ''),
      'text-embedding-3-small'
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_node_id::text, 0));

  -- CASCADE from node_chunks clears chunk_embeddings for this node.
  DELETE FROM node_chunks WHERE node_id = p_node_id;

  INSERT INTO node_chunks (
    node_id, chunk_index, content, context_header, token_count, embedding,
    source_kind, source_id, user_id, content_sha
  )
  SELECT
    p_node_id,
    (elem->>'chunk_index')::integer,
    elem->>'content',
    nullif(elem->>'context_header', ''),
    (elem->>'token_count')::integer,
    (elem->>'embedding')::vector,
    COALESCE(nullif(elem->>'source_kind', ''), 'node'),
    COALESCE(
      nullif(elem->>'source_id', '')::uuid,
      p_node_id
    ),
    v_user_id,
    nullif(elem->>'content_sha', '')
  FROM jsonb_array_elements(p_chunks) AS elem;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Dual-write vectors when an embedding was supplied.
  INSERT INTO chunk_embeddings (chunk_id, model, dim, embedding)
  SELECT nc.id, v_model, 1536, nc.embedding
  FROM node_chunks nc
  WHERE nc.node_id = p_node_id
    AND nc.embedding IS NOT NULL;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION node_chunks_replace(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION node_chunks_replace(uuid, jsonb) TO service_role;

CREATE INDEX IF NOT EXISTS idx_node_chunks_user
  ON node_chunks (user_id);

CREATE INDEX IF NOT EXISTS idx_node_chunks_source
  ON node_chunks (source_kind, source_id);

-- Keep user_id / source_id filled for direct inserts (tests, future asset
-- chunkers) so retrieval keyed on node_chunks.user_id never silently misses.
CREATE OR REPLACE FUNCTION node_chunks_sync_owner()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.user_id IS NULL OR NEW.source_id IS NULL THEN
    SELECT n.user_id,
           COALESCE(NEW.source_id, n.id)
      INTO NEW.user_id, NEW.source_id
    FROM nodes n
    WHERE n.id = NEW.node_id;
  END IF;
  IF NEW.source_kind IS NULL OR NEW.source_kind = '' THEN
    NEW.source_kind := 'node';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_node_chunks_sync_owner ON node_chunks;
CREATE TRIGGER trg_node_chunks_sync_owner
  BEFORE INSERT OR UPDATE OF node_id, user_id, source_id ON node_chunks
  FOR EACH ROW EXECUTE FUNCTION node_chunks_sync_owner();

REVOKE ALL ON FUNCTION node_chunks_sync_owner() FROM PUBLIC, anon, authenticated;
