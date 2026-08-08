-- 00076 · Insights dashboard bootstrap + retention curve cache
-- One authenticated round-trip for Insights; persist full retention simulation
-- on profiles; invalidate after a new review so studying does not leave a
-- stale curve for the full TTL.

-- ---------------------------------------------------------------------
-- 1. Profile columns (server-written only; not in authenticated UPDATE grant)
-- ---------------------------------------------------------------------
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS retention_curve jsonb,
  ADD COLUMN IF NOT EXISTS retention_simulated_at timestamptz;

COMMENT ON COLUMN profiles.retention_curve IS
  'Last retention_simulate_rpc curve_points (+ meta) for Insights/You cache';
COMMENT ON COLUMN profiles.retention_simulated_at IS
  'When retention_curve was last computed; NULL = stale / needs recompute';

-- ---------------------------------------------------------------------
-- 2. retention_simulate_rpc — also persist curve + timestamp
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retention_simulate_rpc(p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  sp scheduling_params;
  horizon constant int := 90;
  node_row record;
  d int;
  s_with numeric;
  s_base numeric;
  days_since_with numeric;
  r_with numeric;
  r_base numeric;
  sum_with numeric[];
  sum_base numeric[];
  node_count int := 0;
  v_review_days int;
  v_is_projected boolean;
  v_memories int := 0;
  v_prev_memories int := 0;
  v_with90 numeric;
  v_base90 numeric;
  curve jsonb;
  result jsonb;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RAISE EXCEPTION 'invalid_input: scheduling_params missing' USING ERRCODE = '22023';
  END IF;

  sum_with := array_fill(0::numeric, ARRAY[horizon + 1]);
  sum_base := array_fill(0::numeric, ARRAY[horizon + 1]);

  SELECT count(DISTINCT activity_date) INTO v_review_days
  FROM daily_activity WHERE user_id = p_user;
  v_review_days := COALESCE(v_review_days, 0);
  v_is_projected := v_review_days < 7;

  FOR node_row IN
    SELECT nd.id,
           GREATEST(COALESCE(nd.stability, sp.s_min), sp.s_min) AS stability,
           nd.difficulty
    FROM nodes nd
    JOIN buckets b ON b.id = nd.bucket_id
    WHERE b.user_id = p_user
      AND nd.deleted_at IS NULL
      AND nd.sr_enabled
      AND b.deleted_at IS NULL
    LIMIT 1000
  LOOP
    node_count := node_count + 1;
    s_with := node_row.stability;
    s_base := node_row.stability;
    days_since_with := 0;
    v_with90 := NULL;
    v_base90 := NULL;

    FOR d IN 0..horizon LOOP
      r_with := engine_r_at_days(s_with, days_since_with);
      r_base := engine_r_at_days(s_base, d);

      sum_with[d + 1] := sum_with[d + 1] + r_with;
      sum_base[d + 1] := sum_base[d + 1] + r_base;

      IF d = horizon THEN
        v_with90 := r_with;
        v_base90 := r_base;
      END IF;

      days_since_with := days_since_with + 1;
      IF engine_r_at_days(s_with, days_since_with) <= sp.target_retention THEN
        s_with := engine_success_stability(
          s_with,
          node_row.difficulty,
          'good'::review_grade,
          engine_r_at_days(s_with, days_since_with)
        );
        days_since_with := 0;
      END IF;
    END LOOP;

    IF (COALESCE(v_with90, 0) - COALESCE(v_base90, 0)) >= 0.15 THEN
      v_memories := v_memories + 1;
    END IF;
  END LOOP;

  IF node_count = 0 THEN
    curve := '[]'::jsonb;
    v_with90 := 0;
    v_base90 := 0;
  ELSE
    SELECT jsonb_agg(
             jsonb_build_object(
               'day', g.d,
               'with_recall', round(sum_with[g.d + 1] / node_count, 4),
               'baseline', round(sum_base[g.d + 1] / node_count, 4)
             )
             ORDER BY g.d
           )
      INTO curve
    FROM generate_series(0, horizon) AS g(d);

    v_with90 := round(sum_with[horizon + 1] / node_count, 4);
    v_base90 := round(sum_base[horizon + 1] / node_count, 4);
  END IF;

  SELECT memories_saved INTO v_prev_memories FROM profiles WHERE id = p_user;
  v_memories := GREATEST(v_memories, COALESCE(v_prev_memories, 0));

  result := jsonb_build_object(
    'retention_with_recall', round(v_with90 * 100, 1),
    'retention_baseline', round(v_base90 * 100, 1),
    'curve_points', curve,
    'is_projected', v_is_projected,
    'review_days_count', v_review_days,
    'memories_saved', v_memories
  );

  UPDATE profiles
  SET retention_with_recall = round(v_with90 * 100, 2),
      retention_baseline = round(v_base90 * 100, 2),
      memories_saved = v_memories,
      retention_curve = result,
      retention_simulated_at = now()
  WHERE id = p_user;

  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION retention_simulate_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION retention_simulate_rpc(uuid) TO service_role;

-- ---------------------------------------------------------------------
-- 3. Invalidate curve after a real review insert (skips ON CONFLICT DO NOTHING)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_invalidate_retention_cache()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE profiles
  SET retention_simulated_at = NULL
  WHERE id = NEW.user_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reviews_invalidate_retention ON reviews;
CREATE TRIGGER reviews_invalidate_retention
  AFTER INSERT ON reviews
  FOR EACH ROW
  EXECUTE FUNCTION trg_invalidate_retention_cache();

REVOKE ALL ON FUNCTION trg_invalidate_retention_cache() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. retention_resolve_rpc — cache hit (15m) or fresh simulate
--    Callable by authenticated (Insights/You share this path).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retention_resolve_rpc(p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  gate jsonb;
  cached jsonb;
  simulated_at timestamptz;
  ttl interval := interval '15 minutes';
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  gate := ai_gate_check(p_user, 'retention_simulate');
  IF COALESCE((gate->>'allowed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%', COALESCE(gate->>'error', 'premium_required')
      USING ERRCODE = 'P0001';
  END IF;

  IF NOT COALESCE(p_force, false) THEN
    SELECT retention_curve, retention_simulated_at
      INTO cached, simulated_at
    FROM profiles
    WHERE id = p_user;

    IF cached IS NOT NULL
       AND simulated_at IS NOT NULL
       AND simulated_at > now() - ttl THEN
      RETURN cached;
    END IF;
  END IF;

  RETURN retention_simulate_rpc(p_user);
END;
$$;

REVOKE ALL ON FUNCTION retention_resolve_rpc(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION retention_resolve_rpc(boolean) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. insights_dashboard_rpc — single bootstrap for Insights tab
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION insights_dashboard_rpc(p_force_retention boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  gate jsonb;
  sim_allowed boolean := false;
  out jsonb := '{}'::jsonb;
  errors jsonb := '{}'::jsonb;
  v_summary jsonb;
  v_activity jsonb;
  v_lifetime jsonb;
  v_teaser jsonb;
  v_retention jsonb;
  v_mastery jsonb;
  v_bucket_count int;
  v_weak jsonb;
  v_velocity jsonb;
  v_notif_stats jsonb;
  v_notif_daily jsonb;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- Spine: summary must succeed.
  SELECT to_jsonb(s) INTO v_summary
  FROM v_insights_summary s
  WHERE s.user_id = p_user;
  out := out || jsonb_build_object('summary', v_summary);

  gate := ai_gate_check(p_user, 'retention_simulate');
  sim_allowed := COALESCE((gate->>'allowed')::boolean, false);
  out := out || jsonb_build_object('simulation_allowed', sim_allowed);

  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.activity_date), '[]'::jsonb)
      INTO v_activity
    FROM v_daily_activity a
    WHERE a.user_id = p_user;
    out := out || jsonb_build_object('daily_activity', COALESCE(v_activity, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('heatmap', true);
    out := out || jsonb_build_object('daily_activity', '[]'::jsonb);
  END;

  IF NOT sim_allowed THEN
    BEGIN
      SELECT to_jsonb(l) INTO v_lifetime
      FROM v_profile_lifetime l
      WHERE l.user_id = p_user;
      out := out || jsonb_build_object('lifetime', v_lifetime);
    EXCEPTION WHEN OTHERS THEN
      errors := errors || jsonb_build_object('teaser', true);
    END;

    BEGIN
      SELECT jsonb_build_object(
               'retention_with_recall', p.retention_with_recall,
               'retention_baseline', p.retention_baseline
             )
        INTO v_teaser
      FROM profiles p
      WHERE p.id = p_user;
      out := out || jsonb_build_object('teaser', v_teaser);
    EXCEPTION WHEN OTHERS THEN
      errors := errors || jsonb_build_object('preview', true);
    END;

    out := out || jsonb_build_object('errors', errors);
    RETURN out;
  END IF;

  -- Premium / relaxed path
  BEGIN
    v_retention := retention_resolve_rpc(p_force_retention);
    out := out || jsonb_build_object('retention', v_retention);
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('retention', true);
    -- Soft fallback: last scalars + curve blob if any
    BEGIN
      SELECT COALESCE(
               p.retention_curve,
               jsonb_build_object(
                 'retention_with_recall', p.retention_with_recall,
                 'retention_baseline', p.retention_baseline,
                 'curve_points', '[]'::jsonb,
                 'is_projected', true,
                 'review_days_count', COALESCE(
                   (SELECT days_with_reviews FROM v_insights_summary WHERE user_id = p_user), 0),
                 'memories_saved', p.memories_saved
               )
             )
        INTO v_retention
      FROM profiles p
      WHERE p.id = p_user
        AND p.retention_with_recall IS NOT NULL;
      IF v_retention IS NOT NULL THEN
        out := out || jsonb_build_object('retention', v_retention);
        errors := errors - 'retention';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  BEGIN
    SELECT count(*)::int INTO v_bucket_count
    FROM buckets b
    WHERE b.user_id = p_user AND b.deleted_at IS NULL;

    SELECT COALESCE(jsonb_agg(row_json ORDER BY node_count DESC), '[]'::jsonb)
      INTO v_mastery
    FROM (
      SELECT jsonb_build_object(
               'label', b.name,
               'progress', LEAST(1.0, GREATEST(0.0, COALESCE(m.mastery_pct, 0))),
               'heat', CASE
                         WHEN COALESCE(h.node_count, 0) = 0 THEN 0.3
                         ELSE LEAST(1.0, GREATEST(0.0,
                           h.due_count::numeric / NULLIF(h.node_count, 0)))
                       END
             ) AS row_json,
             COALESCE(h.node_count, 0) AS node_count
      FROM buckets b
      LEFT JOIN v_bucket_mastery m ON m.bucket_id = b.id AND m.user_id = p_user
      LEFT JOIN v_bucket_heat h ON h.bucket_id = b.id AND h.user_id = p_user
      WHERE b.user_id = p_user AND b.deleted_at IS NULL
      ORDER BY COALESCE(h.node_count, 0) DESC
      LIMIT 4
    ) rings;

    out := out || jsonb_build_object(
      'bucket_count', COALESCE(v_bucket_count, 0),
      'mastery_rings', COALESCE(v_mastery, '[]'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('mastery', true);
  END;

  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(w)), '[]'::jsonb)
      INTO v_weak
    FROM (
      SELECT w.node_id, w.title, w.bucket_id, w.bucket_name,
             w.comfort, w.priority, w.difficulty
      FROM v_weak_topics w
      JOIN buckets b ON b.id = w.bucket_id
      WHERE b.user_id = p_user AND b.deleted_at IS NULL
      ORDER BY w.comfort ASC, w.difficulty DESC
      LIMIT 3
    ) w;
    out := out || jsonb_build_object('weak_topics', COALESCE(v_weak, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('weak', true);
  END;

  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.activity_date), '[]'::jsonb)
      INTO v_velocity
    FROM v_review_velocity_daily v
    WHERE v.user_id = p_user;
    out := out || jsonb_build_object('velocity', COALESCE(v_velocity, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('velocity', true);
  END;

  BEGIN
    SELECT to_jsonb(s) INTO v_notif_stats
    FROM v_notification_stats s
    WHERE s.user_id = p_user;

    SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.day), '[]'::jsonb)
      INTO v_notif_daily
    FROM (
      SELECT nd.day, nd.sent, nd.opened
      FROM v_notification_daily nd
      WHERE nd.user_id = p_user
      ORDER BY nd.day DESC
      LIMIT 7
    ) d;

    out := out || jsonb_build_object(
      'notification_stats', v_notif_stats,
      'notification_daily', COALESCE(v_notif_daily, '[]'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('drops', true);
  END;

  out := out || jsonb_build_object('errors', errors);
  RETURN out;
END;
$$;

REVOKE ALL ON FUNCTION insights_dashboard_rpc(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION insights_dashboard_rpc(boolean) TO authenticated;
