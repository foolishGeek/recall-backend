-- Sprint: Aura AI engine — training-aligned data foundation [D-AI-6].
-- Every AI interaction becomes a clean, RLS-owned, exportable example so a
-- future self-trained model can be fine-tuned on Recall's own data. We capture
-- STRUCTURED signals always; full prompt/context/answer TEXT only when the user
-- opts in (profiles.ai_training_opt_in) or a global capture flag is on.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md.

SET search_path = public, extensions;

-- Consent flag (default off → privacy-safe).
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS ai_training_opt_in boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS ai_interactions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  feature           text NOT NULL,
  scope             jsonb NOT NULL DEFAULT '{}'::jsonb,      -- {mode, bucket_ids, node_ids}
  retrieved_node_ids uuid[] NOT NULL DEFAULT '{}',
  had_notes         boolean NOT NULL DEFAULT false,
  blend             text,                                    -- notes_only | blended | general_only
  model             text,
  latency_ms        integer,
  input_tokens      integer NOT NULL DEFAULT 0,
  output_tokens     integer NOT NULL DEFAULT 0,
  rating            smallint NOT NULL DEFAULT 0,             -- -1 / 0 / +1
  rating_reason     text,
  payload           jsonb,                                   -- full text ONLY when capture allowed
  content_hash      text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_interactions_user_created_idx
  ON ai_interactions (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_interactions_feature_idx
  ON ai_interactions (feature);

ALTER TABLE ai_interactions ENABLE ROW LEVEL SECURITY;

-- Owner can read their own interactions; writes happen via SECURITY DEFINER RPCs.
DROP POLICY IF EXISTS ai_interactions_owner_select ON ai_interactions;
CREATE POLICY ai_interactions_owner_select ON ai_interactions
  FOR SELECT USING (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- ai_log_interaction: append a structured interaction row (service role).
-- Full-text `p_payload` is stored ONLY when the user opted in or the caller
-- passes p_global_capture = true (env flag in ai-forge). Returns the row id so
-- the client can attach a rating later. Never raises into the AI response path.
-- ---------------------------------------------------------------------
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
  p_global_capture boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  opt_in boolean;
  v_id uuid;
BEGIN
  SELECT ai_training_opt_in INTO opt_in FROM profiles WHERE id = p_user;
  INSERT INTO ai_interactions (
    user_id, feature, scope, retrieved_node_ids, had_notes, blend, model,
    latency_ms, input_tokens, output_tokens, payload, content_hash
  ) VALUES (
    p_user, p_feature, COALESCE(p_scope, '{}'::jsonb), COALESCE(p_retrieved, '{}'),
    p_had_notes, p_blend, p_model, p_latency_ms,
    GREATEST(COALESCE(p_input, 0), 0), GREATEST(COALESCE(p_output, 0), 0),
    CASE WHEN (COALESCE(opt_in, false) OR COALESCE(p_global_capture, false)) THEN p_payload ELSE NULL END,
    p_content_hash
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- ai_rate_interaction: the user attaches a rating (+ optional reason) to their
-- own interaction. The reason also feeds per-user personalization downstream.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_rate_interaction(
  p_interaction uuid,
  p_rating smallint,
  p_reason text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ok boolean := false;
BEGIN
  UPDATE ai_interactions
  SET rating = LEAST(GREATEST(COALESCE(p_rating, 0), -1), 1),
      rating_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
  WHERE id = p_interaction AND user_id = auth.uid();
  GET DIAGNOSTICS ok = ROW_COUNT;
  RETURN ok;
END;
$$;

-- Privileges.
REVOKE ALL ON FUNCTION
  ai_log_interaction(uuid, text, jsonb, uuid[], boolean, text, text, integer, integer, integer, jsonb, text, boolean),
  ai_rate_interaction(uuid, smallint, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  ai_log_interaction(uuid, text, jsonb, uuid[], boolean, text, text, integer, integer, integer, jsonb, text, boolean)
TO service_role;
GRANT EXECUTE ON FUNCTION ai_rate_interaction(uuid, smallint, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Training-ready views (offline / service-role analytics only). Explicitly
-- revoked from app clients to avoid any cross-user exposure; service_role
-- bypasses RLS for the export/training pipeline.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_train_rag AS
  SELECT id, user_id, created_at, model, blend, had_notes, retrieved_node_ids,
         rating, rating_reason, payload
  FROM ai_interactions
  WHERE feature = 'rag_chat';

CREATE OR REPLACE VIEW v_train_eval AS
  SELECT e.node_id, n.markdown AS original_markdown, e.suggested_markdown,
         e.quality_score, e.feedback, e.model, e.content_hash, e.created_at
  FROM node_ai_evaluations e
  JOIN nodes n ON n.id = e.node_id;

CREATE OR REPLACE VIEW v_train_quiz AS
  SELECT qqa.id, qa.user_id, qa.mode, qqa.question_json, qqa.user_answer,
         qqa.grade, qqa.is_correct, qqa.created_at
  FROM quiz_question_attempts qqa
  JOIN quiz_attempts qa ON qa.id = qqa.attempt_id;

REVOKE ALL ON v_train_rag, v_train_eval, v_train_quiz FROM PUBLIC, anon, authenticated;
GRANT SELECT ON v_train_rag, v_train_eval, v_train_quiz TO service_role;
