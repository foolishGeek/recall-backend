-- Phase 2 (flagged): per-user FSRS weight optimization — PIPELINE + SAFETY GATE.
--
-- Goal: learn each user's own FSRS-6 weights from their real review history so
-- scheduling fits them better than the published defaults. Industry-standard
-- accuracy comes from the official `fsrs-optimizer` (py-fsrs) — so the heavy
-- lifting runs as a Python job (see jobs/fsrs_optimizer/), not in SQL.
--
-- This migration lands only the SAFE, honest scaffolding:
--   • export_review_history_rpc — feed the optimizer a user's review log.
--   • fsrs_weight_candidates    — store each candidate's weights + its measured
--                                 calibration vs the default engine (the
--                                 evidence for "does it actually beat default").
--   • fsrs_record_candidate_rpc — the job writes a validated candidate here.
--   • fsrs_adopt_candidate_rpc  — adopt ONLY if it beats default by a margin;
--                                 gated by a kill-switch; bumps weights_version.
--
-- IMPORTANT — no dead lever: adopted weights are recorded as *evidence*; they do
-- NOT silently change scheduling. Applying adopted weights to the live engine
-- (threading an optional weights array through the IMMUTABLE helpers + the three
-- RPC boundaries, `COALESCE(p_w[i+1], default)`) is the final, separately-shipped
-- step, gated by `fsrs_per_user_weights_enabled`. Until then this is a
-- measure-and-prove pipeline only — never a hidden influence on reviews.

SET search_path = public, extensions;

INSERT INTO app_config (key, value) VALUES
  ('fsrs_per_user_weights_enabled', 'false'::jsonb),   -- master kill-switch (OFF)
  ('fsrs_adopt_brier_margin', '0.02'::jsonb)           -- must beat default by this
ON CONFLICT (key) DO NOTHING;

-- Candidate weights + the calibration evidence that justifies (or rejects) them.
CREATE TABLE IF NOT EXISTS fsrs_weight_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  weights numeric[] NOT NULL,                 -- exactly 21 (w0..w20)
  weights_version integer NOT NULL DEFAULT 1,
  source text NOT NULL DEFAULT 'fsrs-optimizer',
  n_reviews integer NOT NULL DEFAULT 0,
  brier_candidate numeric,                    -- lower is better
  brier_default numeric,
  ece_candidate numeric,
  ece_default numeric,
  status text NOT NULL DEFAULT 'candidate'    -- candidate | adopted | rejected
    CHECK (status IN ('candidate', 'adopted', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_fsrs_candidates_user
  ON fsrs_weight_candidates (user_id, created_at DESC);
-- At most one adopted set per user (the current best).
CREATE UNIQUE INDEX IF NOT EXISTS uq_fsrs_candidates_adopted
  ON fsrs_weight_candidates (user_id) WHERE status = 'adopted';
ALTER TABLE fsrs_weight_candidates ENABLE ROW LEVEL SECURITY;  -- internal only

-- ---------------------------------------------------------------------
-- export_review_history_rpc — the optimizer's input (service-role).
-- Returns the user's review log as [{card_id, rating, reviewed_at}] with rating
-- 1..4 (again/hard/good/easy) — exactly what fsrs-optimizer expects.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION export_review_history_rpc(
  p_user uuid,
  p_limit integer DEFAULT 50000
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v jsonb;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'reviewed_at')), '[]'::jsonb)
  INTO v
  FROM (
    SELECT jsonb_build_object(
             'card_id', r.node_id,
             'rating', CASE r.grade
                         WHEN 'again'::review_grade THEN 1
                         WHEN 'hard'::review_grade THEN 2
                         WHEN 'good'::review_grade THEN 3
                         WHEN 'easy'::review_grade THEN 4
                       END,
             'reviewed_at', r.reviewed_at
           ) AS row
    FROM reviews r
    WHERE r.user_id = p_user
    ORDER BY r.reviewed_at ASC
    LIMIT p_limit
  ) s;

  RETURN v;
END;
$$;

REVOKE ALL ON FUNCTION export_review_history_rpc(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION export_review_history_rpc(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------
-- fsrs_record_candidate_rpc — the job stores a validated candidate + evidence.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fsrs_record_candidate_rpc(
  p_user uuid,
  p_weights numeric[],
  p_n_reviews integer,
  p_brier_candidate numeric,
  p_brier_default numeric,
  p_ece_candidate numeric DEFAULT NULL,
  p_ece_default numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_version integer;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;
  IF array_length(p_weights, 1) <> 21 THEN
    RAISE EXCEPTION 'invalid_input: expected 21 weights, got %', array_length(p_weights, 1)
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(max(weights_version), 0) + 1 INTO v_version
  FROM fsrs_weight_candidates WHERE user_id = p_user;

  INSERT INTO fsrs_weight_candidates (
    user_id, weights, weights_version, n_reviews,
    brier_candidate, brier_default, ece_candidate, ece_default
  ) VALUES (
    p_user, p_weights, v_version, p_n_reviews,
    p_brier_candidate, p_brier_default, p_ece_candidate, p_ece_default
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION fsrs_record_candidate_rpc(uuid, numeric[], integer, numeric, numeric, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION fsrs_record_candidate_rpc(uuid, numeric[], integer, numeric, numeric, numeric, numeric)
  TO service_role;

-- ---------------------------------------------------------------------
-- fsrs_adopt_candidate_rpc — adopt ONLY if it beats default; kill-switch gated.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fsrs_adopt_candidate_rpc(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c fsrs_weight_candidates%ROWTYPE;
  v_margin numeric := app_config_num('fsrs_adopt_brier_margin', 0.02);
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF NOT app_config_bool('fsrs_per_user_weights_enabled', false) THEN
    RETURN jsonb_build_object('status', 'disabled');
  END IF;

  SELECT * INTO c FROM fsrs_weight_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002';
  END IF;

  -- Adopt only if the candidate's Brier score beats default by the margin.
  IF c.brier_candidate IS NULL OR c.brier_default IS NULL
     OR c.brier_candidate > c.brier_default - v_margin THEN
    UPDATE fsrs_weight_candidates
    SET status = 'rejected', decided_at = now()
    WHERE id = p_candidate_id;
    RETURN jsonb_build_object('status', 'rejected',
      'brier_candidate', c.brier_candidate, 'brier_default', c.brier_default);
  END IF;

  -- Demote any previously-adopted set, then adopt this one.
  UPDATE fsrs_weight_candidates
  SET status = 'rejected', decided_at = now()
  WHERE user_id = c.user_id AND status = 'adopted';

  UPDATE fsrs_weight_candidates
  SET status = 'adopted', decided_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object('status', 'adopted', 'weights_version', c.weights_version,
    'brier_candidate', c.brier_candidate, 'brier_default', c.brier_default);
END;
$$;

REVOKE ALL ON FUNCTION fsrs_adopt_candidate_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION fsrs_adopt_candidate_rpc(uuid) TO service_role;
