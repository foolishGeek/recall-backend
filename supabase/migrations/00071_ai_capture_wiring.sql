-- Phase 8/9 wiring: the tables from 00069/00070 existed but nothing wrote to
-- them. This adds the write paths and the consent/retention teeth:
--   * ingest lineage columns the parser already knows (mime, bytes, sha, pages)
--   * the feedback vocabulary from the plan + an owner-safe write RPC
--   * a bulk writer for retrieval candidates (near-misses = reranker training)
--   * retention: captured text expires, structured rows stay
--   * opting out of training redacts what was already captured
--   * request cost in currency, so self-hosting can be argued with numbers

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Ingest lineage: everything needed to reproduce a parse
-- ---------------------------------------------------------------------

ALTER TABLE ingest_documents
  ADD COLUMN IF NOT EXISTS source_id uuid,
  ADD COLUMN IF NOT EXISTS mime_type text,
  ADD COLUMN IF NOT EXISTS bytes bigint,
  ADD COLUMN IF NOT EXISTS sha256 text,
  ADD COLUMN IF NOT EXISTS parser text,
  ADD COLUMN IF NOT EXISTS parser_version text,
  ADD COLUMN IF NOT EXISTS error text;

-- Re-parsing the same file must update one row, not pile up duplicates.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ingest_documents_path_sha
  ON ingest_documents (user_id, storage_path, sha256)
  WHERE storage_path IS NOT NULL AND sha256 IS NOT NULL;

ALTER TABLE ingest_segments
  ADD COLUMN IF NOT EXISTS char_start integer,
  ADD COLUMN IF NOT EXISTS char_end integer,
  ADD COLUMN IF NOT EXISTS token_count integer;

-- ---------------------------------------------------------------------
-- Feedback vocabulary [plan Phase 8]
-- ---------------------------------------------------------------------

-- Normalise the two names the stub used before widening the constraint.
UPDATE ai_feedback SET kind = 'citation_opened' WHERE kind = 'citation_open';
UPDATE ai_feedback SET kind = 'answer_copied' WHERE kind = 'copy';

ALTER TABLE ai_feedback DROP CONSTRAINT IF EXISTS ai_feedback_kind_chk;
ALTER TABLE ai_feedback ADD CONSTRAINT ai_feedback_kind_chk CHECK (
  kind IN (
    'thumb',            -- explicit rating
    'suggestion',       -- free-text suggestion turned into a directive
    'regenerate',       -- preference pair: this answer replaced another
    'citation_opened',  -- weak relevance label for the embedder
    'answer_copied',    -- weak positive
    'edit_accepted',    -- the user kept our rewrite
    'stream_abandoned', -- the user stopped reading
    'report'            -- flagged as wrong or unsafe
  )
);

-- One vote per kind per interaction; re-tapping updates instead of duplicating.
-- Regenerate pairs are events, not votes, so they are excluded.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_feedback_once
  ON ai_feedback (interaction_id, kind)
  WHERE kind <> 'regenerate';

/**
 * Record a feedback signal for one of the caller's own interactions.
 * Weak signals (citation opens, copies, abandons) are what make the retriever
 * trainable without any human labelling, so the client can write them directly.
 */
CREATE OR REPLACE FUNCTION ai_record_feedback(
  p_interaction uuid,
  p_kind text,
  p_value smallint DEFAULT NULL,
  p_text text DEFAULT NULL,
  p_replaced uuid DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid;
BEGIN
  SELECT user_id INTO v_user
  FROM ai_interactions
  WHERE id = p_interaction AND user_id = auth.uid();

  IF v_user IS NULL THEN RETURN false; END IF;

  INSERT INTO ai_feedback (user_id, interaction_id, kind, value, text, replaced_interaction_id)
  VALUES (
    v_user, p_interaction, p_kind,
    LEAST(GREATEST(COALESCE(p_value, 0), -1), 1),
    NULLIF(btrim(COALESCE(p_text, '')), ''),
    p_replaced
  )
  ON CONFLICT (interaction_id, kind) WHERE kind <> 'regenerate'
  DO UPDATE SET
    value = EXCLUDED.value,
    text = COALESCE(EXCLUDED.text, ai_feedback.text),
    created_at = now();

  -- Keep the legacy column the mobile list still reads.
  IF p_kind = 'thumb' THEN
    UPDATE ai_interactions
    SET rating = LEAST(GREATEST(COALESCE(p_value, 0), -1), 1),
        rating_reason = NULLIF(btrim(COALESCE(p_text, '')), '')
    WHERE id = p_interaction;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION ai_record_feedback(uuid, text, smallint, text, uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ai_record_feedback(uuid, text, smallint, text, uuid)
TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Retrieval candidates: bulk writer
-- ---------------------------------------------------------------------

/**
 * Append the candidate set for one interaction. Accepts the array the Edge
 * Function already has in hand; a bad row is skipped rather than failing the
 * answer, because capture must never break a response.
 */
CREATE OR REPLACE FUNCTION ai_log_retrieval_candidates(
  p_interaction uuid,
  p_candidates jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  written integer := 0;
BEGIN
  IF p_interaction IS NULL OR p_candidates IS NULL
     OR jsonb_typeof(p_candidates) <> 'array' THEN
    RETURN 0;
  END IF;

  INSERT INTO ai_retrieval_candidates (
    interaction_id, rank, source_kind, source_id, chunk_id,
    keyword_score, vector_score, rerank_score, used
  )
  SELECT
    p_interaction,
    COALESCE((c->>'rank')::int, ord),
    COALESCE(NULLIF(c->>'source_kind', ''), 'node'),
    NULLIF(c->>'source_id', '')::uuid,
    NULLIF(c->>'chunk_id', '')::uuid,
    (c->>'keyword_score')::double precision,
    (c->>'vector_score')::double precision,
    (c->>'rerank_score')::double precision,
    COALESCE((c->>'used')::boolean, false)
  FROM jsonb_array_elements(p_candidates) WITH ORDINALITY AS t(c, ord);

  GET DIAGNOSTICS written = ROW_COUNT;
  RETURN written;
END;
$$;

REVOKE ALL ON FUNCTION ai_log_retrieval_candidates(uuid, jsonb)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_log_retrieval_candidates(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------
-- Retention + consent
-- ---------------------------------------------------------------------

INSERT INTO app_config (key, value) VALUES
  -- How long captured prompt/answer text is kept. Structured metrics are kept
  -- regardless; only the free text expires.
  ('ai_capture_retention_days', '730'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- Stamp retention on capture so every row carries its own expiry.
CREATE OR REPLACE FUNCTION ai_interactions_set_retention()
RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  days integer;
BEGIN
  IF NEW.payload IS NOT NULL AND NEW.retention_until IS NULL THEN
    SELECT COALESCE((value #>> '{}')::integer, 730) INTO days
    FROM app_config WHERE key = 'ai_capture_retention_days';
    NEW.retention_until := now() + make_interval(days => COALESCE(days, 730));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_ai_interactions_retention ON ai_interactions;
CREATE TRIGGER trigger_ai_interactions_retention
  BEFORE INSERT ON ai_interactions
  FOR EACH ROW EXECUTE FUNCTION ai_interactions_set_retention();

/**
 * Drop expired free text, keep the structured row. Batched so the cron never
 * holds a long transaction.
 */
CREATE OR REPLACE FUNCTION ai_redact_expired_interactions(p_limit integer DEFAULT 2000)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  redacted integer := 0;
BEGIN
  WITH due AS (
    SELECT id FROM ai_interactions
    WHERE payload IS NOT NULL
      AND redacted_at IS NULL
      AND retention_until IS NOT NULL
      AND retention_until <= now()
    ORDER BY retention_until
    LIMIT GREATEST(COALESCE(p_limit, 2000), 1)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE ai_interactions i
  SET payload = NULL, redacted_at = now()
  FROM due
  WHERE i.id = due.id;

  GET DIAGNOSTICS redacted = ROW_COUNT;

  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('ai-redact-expired', 'ok', 'redacted=' || redacted);

  RETURN redacted;
END;
$$;

REVOKE ALL ON FUNCTION ai_redact_expired_interactions(integer)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_redact_expired_interactions(integer) TO service_role;

-- Withdrawing training consent must reach data already captured, otherwise the
-- opt-in toggle is decorative. Expiring it now hands it to the same cron.
CREATE OR REPLACE FUNCTION ai_training_opt_out_redacts()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF COALESCE(OLD.ai_training_opt_in, false) = true
     AND COALESCE(NEW.ai_training_opt_in, false) = false THEN
    UPDATE ai_interactions
    SET retention_until = now()
    WHERE user_id = NEW.id AND payload IS NOT NULL AND redacted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_ai_training_opt_out ON profiles;
CREATE TRIGGER trigger_ai_training_opt_out
  AFTER UPDATE OF ai_training_opt_in ON profiles
  FOR EACH ROW EXECUTE FUNCTION ai_training_opt_out_redacts();

DO $$
BEGIN
  PERFORM cron.unschedule('ai-redact-expired');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

DO $$
BEGIN
  PERFORM cron.schedule(
    'ai-redact-expired',
    '17 4 * * *',
    $cron$ SELECT public.ai_redact_expired_interactions(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping ai-redact-expired schedule';
END;
$$;

-- ---------------------------------------------------------------------
-- Request cost in currency
-- ---------------------------------------------------------------------

-- Price a request against the pricing row in force when it ran, so a later
-- price change never rewrites history.
CREATE OR REPLACE VIEW v_ai_request_cost AS
SELECT
  r.id,
  r.user_id,
  r.feature,
  r.tier,
  r.status,
  r.model,
  r.provider,
  r.input_tokens,
  r.output_tokens,
  r.reserved_at,
  p.currency,
  ROUND(
    (r.input_tokens / 1000000.0) * p.input_per_mtok
    + (r.output_tokens / 1000000.0) * p.output_per_mtok,
    6
  ) AS cost
FROM ai_requests r
LEFT JOIN LATERAL (
  SELECT mp.input_per_mtok, mp.output_per_mtok, mp.currency
  FROM ai_model_pricing mp
  WHERE mp.model = r.model
    AND (r.provider IS NULL OR mp.provider = r.provider)
    AND mp.effective_from <= r.reserved_at
  ORDER BY mp.effective_from DESC
  LIMIT 1
) p ON true;

REVOKE ALL ON v_ai_request_cost FROM PUBLIC, anon, authenticated;
GRANT SELECT ON v_ai_request_cost TO service_role;

COMMENT ON TABLE ai_retrieval_candidates IS
  'Retrieval near-misses alongside the winners. Written by ai_log_retrieval_candidates; this is the reranker/embedder training set.';
COMMENT ON VIEW v_ai_request_cost IS
  'Per-request cost in currency, priced at the rate in force when the request ran.';
