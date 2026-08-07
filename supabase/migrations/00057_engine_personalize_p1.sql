-- Phase 1 personalization (behavioral). Three data-driven, low-risk additions
-- on top of the published FSRS-6 defaults — no change to the scheduling math:
--
--   1. engine_calibration_rpc: the objective "is it working" metric. Compares
--      the engine's predicted recall (reviews.retrievability_before) with what
--      actually happened (grade <> 'again') and returns Brier score + Expected
--      Calibration Error (ECE) + per-decile bins. This is how we prove the
--      engine (and any future per-user tuning) actually helps.
--
--   2. engine_preferred_drop_hour: the user's real most-active review hour (in
--      their tz) from history — the signal for smarter Drop timing.
--
--   3. Target-retention auto-tuning: gently nudges the user-level Memory Strength
--      toward the value that makes their *experienced* recall match their goal,
--      bounded [0.80, 0.97], one small step per run. FLAG-GATED (default OFF),
--      TRANSPARENT (every change is logged), and it NEVER overwrites a value the
--      user set by hand (auto_tuned marker). Off until an owner enables it after
--      reviewing calibration on real data.

SET search_path = public, extensions;

-- Numeric app_config reader (we only had int/bool).
CREATE OR REPLACE FUNCTION app_config_num(p_key text, p_default numeric)
RETURNS numeric
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE((SELECT value::text::numeric FROM app_config WHERE key = p_key), p_default);
$$;

INSERT INTO app_config (key, value) VALUES
  ('retention_autotune_enabled', 'false'::jsonb),   -- master kill-switch (OFF)
  ('retention_autotune_min_reviews', '50'::jsonb),  -- need enough signal
  ('retention_autotune_step', '0.01'::jsonb),       -- max move per run
  ('retention_autotune_margin', '0.03'::jsonb)      -- dead-band around goal
ON CONFLICT (key) DO NOTHING;

-- Transparency: mark auto-managed target_retention + when it last moved, so a
-- manual set (auto_tuned=false) is never clobbered by the tuner.
ALTER TABLE scheduling_params
  ADD COLUMN IF NOT EXISTS auto_tuned boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS auto_tuned_at timestamptz;

-- Auditable history of every auto-tune move (internal; RLS on, no policies).
CREATE TABLE IF NOT EXISTS scheduling_autotune_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  old_retention numeric,
  new_retention numeric,
  observed_recall numeric,
  n_reviews integer,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_autotune_log_user_created
  ON scheduling_autotune_log (user_id, created_at DESC);
ALTER TABLE scheduling_autotune_log ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- 1. Calibration metric (predicted R vs actual recall)
-- ---------------------------------------------------------------------
-- p_user NULL → the caller (authenticated self-service). A non-null p_user is
-- only honored for service_role (batch/insights jobs).
CREATE OR REPLACE FUNCTION engine_calibration_rpc(
  p_user uuid DEFAULT NULL,
  p_limit integer DEFAULT 1000
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  target uuid;
  v_n integer := 0;
  v_pred numeric;
  v_actual numeric;
  v_brier numeric;
  v_ece numeric;
  v_bins jsonb;
BEGIN
  target := COALESCE(p_user, auth.uid());
  IF target IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;
  IF target <> auth.uid() AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  WITH r AS (
    SELECT
      retrievability_before AS p,
      CASE WHEN grade <> 'again'::review_grade THEN 1.0 ELSE 0.0 END AS actual
    FROM reviews
    WHERE user_id = target
      AND stability_before IS NOT NULL      -- exclude first reviews (no prediction)
      AND retrievability_before IS NOT NULL
    ORDER BY reviewed_at DESC
    LIMIT p_limit
  ),
  agg AS (
    SELECT count(*)::int AS n, avg(p) AS pred, avg(actual) AS actual,
           avg((p - actual) * (p - actual)) AS brier
    FROM r
  ),
  bins AS (
    SELECT width_bucket(p, 0, 1, 10) AS b, count(*) AS n, avg(p) AS mp, avg(actual) AS ma
    FROM r GROUP BY 1
  ),
  ece AS (
    SELECT CASE WHEN sum(n) > 0
             THEN sum(n * abs(mp - ma)) / sum(n)
             ELSE NULL END AS v
    FROM bins
  )
  SELECT agg.n, round(agg.pred, 4), round(agg.actual, 4), round(agg.brier, 4),
         round(ece.v, 4),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'bin', b, 'n', n,
                    'predicted', round(mp, 4), 'actual', round(ma, 4)) ORDER BY b)
           FROM bins
         ), '[]'::jsonb)
    INTO v_n, v_pred, v_actual, v_brier, v_ece, v_bins
  FROM agg, ece;

  RETURN jsonb_build_object(
    'n_reviews', COALESCE(v_n, 0),
    'predicted_recall', v_pred,
    'actual_recall', v_actual,
    'brier', v_brier,
    'ece', v_ece,
    'bins', v_bins
  );
END;
$$;

REVOKE ALL ON FUNCTION engine_calibration_rpc(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION engine_calibration_rpc(uuid, integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Preferred Drop hour (modal review hour in the user's tz)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION engine_preferred_drop_hour(p_user uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH tz AS (
    SELECT COALESCE(timezone, 'UTC') AS z FROM profiles WHERE id = p_user
  ),
  hrs AS (
    SELECT extract(hour FROM (r.reviewed_at AT TIME ZONE (SELECT z FROM tz)))::int AS h
    FROM reviews r
    WHERE r.user_id = p_user
      AND r.reviewed_at > now() - interval '90 days'
  )
  SELECT h FROM hrs
  GROUP BY h
  HAVING count(*) >= 5           -- need a real habit, not a couple of taps
  ORDER BY count(*) DESC, h ASC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION engine_preferred_drop_hour(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION engine_preferred_drop_hour(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. Target-retention auto-tune (single user) — flag-gated + transparent
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION engine_autotune_retention(p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_enabled boolean := app_config_bool('retention_autotune_enabled', false);
  v_min integer := app_config_int('retention_autotune_min_reviews', 50);
  v_step numeric := app_config_num('retention_autotune_step', 0.01);
  v_margin numeric := app_config_num('retention_autotune_margin', 0.03);
  cal jsonb;
  v_n integer;
  v_actual numeric;
  cur scheduling_params%ROWTYPE;      -- user-level row (may be absent)
  parent scheduling_params%ROWTYPE;   -- global defaults
  v_current numeric;
  v_new numeric;
  v_has_user_row boolean;
BEGIN
  IF NOT v_enabled THEN
    RETURN jsonb_build_object('status', 'disabled');
  END IF;

  cal := engine_calibration_rpc(p_user, 500);
  v_n := (cal->>'n_reviews')::integer;
  v_actual := (cal->>'actual_recall')::numeric;
  IF v_n < v_min OR v_actual IS NULL THEN
    RETURN jsonb_build_object('status', 'insufficient_data', 'n_reviews', v_n);
  END IF;

  SELECT * INTO cur FROM scheduling_params
  WHERE user_id = p_user AND bucket_id IS NULL;
  v_has_user_row := FOUND;

  -- Never clobber a value the user set by hand.
  IF v_has_user_row AND NOT cur.auto_tuned THEN
    RETURN jsonb_build_object('status', 'manual_override');
  END IF;

  -- Effective current target (user row if present, else global default).
  SELECT * INTO parent FROM scheduling_params
  WHERE user_id IS NULL AND bucket_id IS NULL;
  v_current := COALESCE(cur.target_retention, parent.target_retention, 0.90);

  -- If experienced recall is below the goal, memory is decaying faster than the
  -- schedule assumes → raise target (shorter intervals). If above, relax it.
  IF v_actual < v_current - v_margin THEN
    v_new := LEAST(0.97, v_current + v_step);
  ELSIF v_actual > v_current + v_margin THEN
    v_new := GREATEST(0.80, v_current - v_step);
  ELSE
    RETURN jsonb_build_object('status', 'in_band', 'target_retention', v_current,
                              'observed_recall', v_actual);
  END IF;

  IF round(v_new, 4) = round(v_current, 4) THEN
    RETURN jsonb_build_object('status', 'at_bound', 'target_retention', v_current);
  END IF;

  INSERT INTO scheduling_params (
    user_id, bucket_id, target_retention,
    s_min, comfort_k, hard_penalty, easy_bonus,
    new_per_day, session_size, max_new_per_stack, max_per_bucket,
    lookahead_hours, temperature, drop_threshold, leech_lapse_threshold,
    auto_tuned, auto_tuned_at
  ) VALUES (
    p_user, NULL, v_new,
    parent.s_min, parent.comfort_k, parent.hard_penalty, parent.easy_bonus,
    parent.new_per_day, parent.session_size, parent.max_new_per_stack,
    parent.max_per_bucket, parent.lookahead_hours, parent.temperature,
    parent.drop_threshold, parent.leech_lapse_threshold,
    true, now()
  )
  ON CONFLICT (user_id, bucket_id)
  DO UPDATE SET target_retention = EXCLUDED.target_retention,
                auto_tuned = true,
                auto_tuned_at = now();

  INSERT INTO scheduling_autotune_log (user_id, old_retention, new_retention, observed_recall, n_reviews)
  VALUES (p_user, v_current, v_new, v_actual, v_n);

  RETURN jsonb_build_object('status', 'tuned', 'from', v_current, 'to', v_new,
                            'observed_recall', v_actual, 'n_reviews', v_n);
END;
$$;

REVOKE ALL ON FUNCTION engine_autotune_retention(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION engine_autotune_retention(uuid) TO service_role;

-- Batch entry point for a scheduled job. No-op while the flag is OFF.
CREATE OR REPLACE FUNCTION engine_autotune_retention_all()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid;
  v_tuned integer := 0;
  v_res jsonb;
BEGIN
  IF NOT app_config_bool('retention_autotune_enabled', false) THEN
    RETURN 0;
  END IF;

  FOR v_user IN
    SELECT DISTINCT user_id FROM reviews
    WHERE reviewed_at > now() - interval '30 days'
  LOOP
    v_res := engine_autotune_retention(v_user);
    IF v_res->>'status' = 'tuned' THEN
      v_tuned := v_tuned + 1;
    END IF;
  END LOOP;

  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('retention-autotune', 'ok', 'tuned=' || v_tuned);
  RETURN v_tuned;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('retention-autotune', 'error', SQLERRM);
  RETURN v_tuned;
END;
$$;

REVOKE ALL ON FUNCTION engine_autotune_retention_all() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION engine_autotune_retention_all() TO service_role;

-- ---------------------------------------------------------------------
-- Keep the manual-override marker honest: a hand-set Memory Strength clears
-- auto_tuned so the tuner won't touch it. (Re-emits 00053 body + marker.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_scheduling_prefs_rpc(
  p_bucket_id uuid DEFAULT NULL,
  p_target_retention numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  v_clamped numeric;
  parent scheduling_params%ROWTYPE;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF p_bucket_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM buckets
      WHERE id = p_bucket_id AND user_id = p_user AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_target_retention IS NULL THEN
    IF p_bucket_id IS NULL THEN
      DELETE FROM scheduling_params
      WHERE user_id = p_user AND bucket_id IS NULL;
    ELSE
      DELETE FROM scheduling_params
      WHERE bucket_id = p_bucket_id;
    END IF;
    RETURN get_scheduling_prefs_rpc(p_bucket_id);
  END IF;

  v_clamped := LEAST(0.97, GREATEST(0.80, p_target_retention));

  IF p_bucket_id IS NULL THEN
    SELECT * INTO parent
    FROM scheduling_params
    WHERE user_id IS NULL AND bucket_id IS NULL;
  ELSE
    SELECT * INTO parent FROM engine_params(p_user, NULL);
  END IF;

  IF parent.id IS NULL THEN
    RAISE EXCEPTION 'invalid_input: scheduling_params missing' USING ERRCODE = '22023';
  END IF;

  INSERT INTO scheduling_params (
    user_id, bucket_id, target_retention,
    s_min, comfort_k, hard_penalty, easy_bonus,
    new_per_day, session_size, max_new_per_stack, max_per_bucket,
    lookahead_hours, temperature, drop_threshold, leech_lapse_threshold,
    auto_tuned, auto_tuned_at
  ) VALUES (
    p_user, p_bucket_id, v_clamped,
    parent.s_min, parent.comfort_k, parent.hard_penalty, parent.easy_bonus,
    parent.new_per_day, parent.session_size, parent.max_new_per_stack,
    parent.max_per_bucket, parent.lookahead_hours, parent.temperature,
    parent.drop_threshold, parent.leech_lapse_threshold,
    false, NULL
  )
  ON CONFLICT (user_id, bucket_id)
  DO UPDATE SET target_retention = EXCLUDED.target_retention,
                auto_tuned = false,
                auto_tuned_at = NULL;

  RETURN get_scheduling_prefs_rpc(p_bucket_id);
END;
$$;
