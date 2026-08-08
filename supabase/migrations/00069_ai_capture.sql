-- Phase 8: full AI capture spine — prompt versions, retrieval candidates,
-- feedback, and ingest documents/segments so training examples are reproducible
-- and PDF page structure is not thrown away.
--
-- Additive on ai_interactions; ai_rate_interaction keeps writing the legacy
-- rating columns and dual-writes into ai_feedback.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Prompt versions (content-addressed)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_prompt_versions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_sha text NOT NULL,
  feature     text NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (content_sha)
);

CREATE INDEX IF NOT EXISTS idx_ai_prompt_versions_feature
  ON ai_prompt_versions (feature, created_at DESC);

ALTER TABLE ai_prompt_versions ENABLE ROW LEVEL SECURITY;
-- Internal catalogue; service_role only (no policies for authenticated).

-- ---------------------------------------------------------------------
-- Extend ai_interactions
-- ---------------------------------------------------------------------

ALTER TABLE ai_interactions
  ADD COLUMN IF NOT EXISTS request_id uuid REFERENCES ai_requests(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS prompt_id uuid REFERENCES ai_prompt_versions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS prompt_version text,
  ADD COLUMN IF NOT EXISTS system_prompt_sha text,
  ADD COLUMN IF NOT EXISTS provider text,
  ADD COLUMN IF NOT EXISTS provider_request_id text,
  ADD COLUMN IF NOT EXISTS temperature numeric(3,2),
  ADD COLUMN IF NOT EXISTS max_tokens integer,
  ADD COLUMN IF NOT EXISTS scope_kind text,
  ADD COLUMN IF NOT EXISTS retrieval_mode text,
  ADD COLUMN IF NOT EXISTS conversation_id uuid REFERENCES ai_conversations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS schema_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS redacted_at timestamptz,
  ADD COLUMN IF NOT EXISTS retention_until timestamptz,
  ADD COLUMN IF NOT EXISTS error_code text;

CREATE INDEX IF NOT EXISTS idx_ai_interactions_request
  ON ai_interactions (request_id)
  WHERE request_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_interactions_conversation
  ON ai_interactions (conversation_id)
  WHERE conversation_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- Retrieval candidates (accepted + rejected)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_retrieval_candidates (
  id              bigserial PRIMARY KEY,
  interaction_id  uuid NOT NULL REFERENCES ai_interactions(id) ON DELETE CASCADE,
  rank            integer NOT NULL,
  source_kind     text NOT NULL DEFAULT 'node',
  source_id       uuid,
  chunk_id        uuid,
  keyword_score   double precision,
  vector_score    double precision,
  rerank_score    double precision,
  used            boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_ai_retrieval_candidates_interaction
  ON ai_retrieval_candidates (interaction_id, rank);

ALTER TABLE ai_retrieval_candidates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_retrieval_candidates_owner_select ON ai_retrieval_candidates;
CREATE POLICY ai_retrieval_candidates_owner_select ON ai_retrieval_candidates
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM ai_interactions i
      WHERE i.id = interaction_id AND i.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------
-- Feedback (thumbs + regenerate pairs + weak labels)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_feedback (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  interaction_id          uuid NOT NULL REFERENCES ai_interactions(id) ON DELETE CASCADE,
  kind                    text NOT NULL,
  value                   smallint,
  text                    text,
  replaced_interaction_id uuid REFERENCES ai_interactions(id) ON DELETE SET NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ai_feedback_kind_chk
    CHECK (kind IN ('thumb', 'regenerate', 'citation_open', 'copy', 'report'))
);

CREATE INDEX IF NOT EXISTS idx_ai_feedback_interaction
  ON ai_feedback (interaction_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_feedback_user
  ON ai_feedback (user_id, created_at DESC);

ALTER TABLE ai_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_feedback_owner_select ON ai_feedback;
CREATE POLICY ai_feedback_owner_select ON ai_feedback
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Migrate existing thumbs into ai_feedback without touching the legacy columns.
INSERT INTO ai_feedback (user_id, interaction_id, kind, value, text, created_at)
SELECT i.user_id, i.id, 'thumb', i.rating, i.rating_reason, i.created_at
FROM ai_interactions i
WHERE i.rating <> 0
  AND NOT EXISTS (
    SELECT 1 FROM ai_feedback f
    WHERE f.interaction_id = i.id AND f.kind = 'thumb'
  );

-- ---------------------------------------------------------------------
-- Ingest documents / segments (PDF page structure)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ingest_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  node_id       uuid REFERENCES nodes(id) ON DELETE SET NULL,
  asset_id      uuid REFERENCES node_assets(id) ON DELETE SET NULL,
  source_kind   text NOT NULL DEFAULT 'pdf',
  storage_path  text,
  page_count    integer,
  status        text NOT NULL DEFAULT 'ready',
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ingest_documents_status_chk
    CHECK (status IN ('pending', 'processing', 'ready', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_ingest_documents_user
  ON ingest_documents (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ingest_documents_node
  ON ingest_documents (node_id)
  WHERE node_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ingest_segments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   uuid NOT NULL REFERENCES ingest_documents(id) ON DELETE CASCADE,
  segment_index integer NOT NULL,
  page_number   integer,
  content       text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, segment_index)
);

CREATE INDEX IF NOT EXISTS idx_ingest_segments_document
  ON ingest_segments (document_id, segment_index);

ALTER TABLE ingest_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingest_segments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ingest_documents_owner_select ON ingest_documents;
CREATE POLICY ingest_documents_owner_select ON ingest_documents
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS ingest_segments_owner_select ON ingest_segments;
CREATE POLICY ingest_segments_owner_select ON ingest_segments
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM ingest_documents d
      WHERE d.id = document_id AND d.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------
-- ai_log_interaction: accept capture fields (defaults keep old callers working)
-- ---------------------------------------------------------------------

-- Drop the shorter 00020 signature so callers bind to the extended one
-- (CREATE OR REPLACE cannot change the argument list in place).
DROP FUNCTION IF EXISTS ai_log_interaction(
  uuid, text, jsonb, uuid[], boolean, text, text, integer, integer, integer,
  jsonb, text, boolean
);

CREATE OR REPLACE FUNCTION ai_log_interaction(
  p_user uuid,
  p_feature text,
  p_scope jsonb DEFAULT '{}'::jsonb,
  p_retrieved uuid[] DEFAULT '{}',
  p_had_notes boolean DEFAULT false,
  p_blend text DEFAULT NULL,
  p_model text DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL,
  p_input integer DEFAULT 0,
  p_output integer DEFAULT 0,
  p_payload jsonb DEFAULT NULL,
  p_content_hash text DEFAULT NULL,
  p_global_capture boolean DEFAULT false,
  p_request_id uuid DEFAULT NULL,
  p_prompt_id uuid DEFAULT NULL,
  p_prompt_version text DEFAULT NULL,
  p_system_prompt_sha text DEFAULT NULL,
  p_provider text DEFAULT NULL,
  p_provider_request_id text DEFAULT NULL,
  p_temperature numeric DEFAULT NULL,
  p_max_tokens integer DEFAULT NULL,
  p_scope_kind text DEFAULT NULL,
  p_retrieval_mode text DEFAULT NULL,
  p_conversation_id uuid DEFAULT NULL,
  p_error_code text DEFAULT NULL,
  p_retention_until timestamptz DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  opt_in boolean;
  v_id uuid;
BEGIN
  SELECT ai_training_opt_in INTO opt_in FROM profiles WHERE id = p_user;
  INSERT INTO ai_interactions (
    user_id, feature, scope, retrieved_node_ids, had_notes, blend, model,
    latency_ms, input_tokens, output_tokens, payload, content_hash,
    request_id, prompt_id, prompt_version, system_prompt_sha, provider,
    provider_request_id, temperature, max_tokens, scope_kind, retrieval_mode,
    conversation_id, error_code, retention_until, schema_version
  ) VALUES (
    p_user, p_feature, COALESCE(p_scope, '{}'::jsonb), COALESCE(p_retrieved, '{}'),
    p_had_notes, p_blend, p_model, p_latency_ms,
    GREATEST(COALESCE(p_input, 0), 0), GREATEST(COALESCE(p_output, 0), 0),
    CASE WHEN (COALESCE(opt_in, false) OR COALESCE(p_global_capture, false))
         THEN p_payload ELSE NULL END,
    p_content_hash,
    p_request_id, p_prompt_id, p_prompt_version, p_system_prompt_sha, p_provider,
    p_provider_request_id, p_temperature, p_max_tokens, p_scope_kind, p_retrieval_mode,
    p_conversation_id, p_error_code, p_retention_until, 1
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Dual-write thumbs into ai_feedback; keep legacy columns for mobile.
CREATE OR REPLACE FUNCTION ai_rate_interaction(
  p_interaction uuid,
  p_rating smallint,
  p_reason text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ok boolean := false;
  v_user uuid;
  v_value smallint;
  v_text text;
BEGIN
  v_value := LEAST(GREATEST(COALESCE(p_rating, 0), -1), 1);
  v_text := NULLIF(btrim(COALESCE(p_reason, '')), '');

  UPDATE ai_interactions
  SET rating = v_value,
      rating_reason = v_text
  WHERE id = p_interaction AND user_id = auth.uid()
  RETURNING user_id INTO v_user;

  GET DIAGNOSTICS ok = ROW_COUNT;
  IF NOT ok THEN RETURN false; END IF;

  IF v_value <> 0 THEN
    INSERT INTO ai_feedback (user_id, interaction_id, kind, value, text)
    VALUES (v_user, p_interaction, 'thumb', v_value, v_text);
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION
  ai_log_interaction(
    uuid, text, jsonb, uuid[], boolean, text, text, integer, integer, integer,
    jsonb, text, boolean, uuid, uuid, text, text, text, text, numeric, integer,
    text, text, uuid, text, timestamptz
  ),
  ai_rate_interaction(uuid, smallint, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  ai_log_interaction(
    uuid, text, jsonb, uuid[], boolean, text, text, integer, integer, integer,
    jsonb, text, boolean, uuid, uuid, text, text, text, text, numeric, integer,
    text, text, uuid, text, timestamptz
  )
TO service_role;

GRANT EXECUTE ON FUNCTION ai_rate_interaction(uuid, smallint, text)
TO authenticated, service_role;

-- Helper: register a prompt body by content hash (service role).
CREATE OR REPLACE FUNCTION ai_register_prompt(
  p_feature text,
  p_body text,
  p_content_sha text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO ai_prompt_versions (content_sha, feature, body)
  VALUES (p_content_sha, p_feature, p_body)
  ON CONFLICT (content_sha) DO UPDATE
    SET feature = EXCLUDED.feature
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION ai_register_prompt(text, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_register_prompt(text, text, text) TO service_role;
