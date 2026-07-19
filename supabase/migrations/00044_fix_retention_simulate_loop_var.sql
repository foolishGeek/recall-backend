-- Fix retention_simulate_rpc: FOR-loop record `n` collided with table alias `n`
-- ("record n is not assigned yet"). Rename loop var + table alias.
-- Unblocks You/Insights simulation for all users while limits_profile=relaxed.

SET search_path = public, extensions;

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
           GREATEST(
             COALESCE(nd.stability, engine_stability_from_comfort(nd.comfort, sp.comfort_k)),
             sp.s_min
           ) AS stability,
           nd.difficulty
    FROM nodes nd
    JOIN buckets b ON b.id = nd.bucket_id
    WHERE b.user_id = p_user
      AND nd.deleted_at IS NULL
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
      r_with := power(1 + (days_since_with / (9.0 * s_with)), -1)::numeric;
      r_base := power(1 + (d / (9.0 * s_base)), -1)::numeric;

      sum_with[d + 1] := sum_with[d + 1] + r_with;
      sum_base[d + 1] := sum_base[d + 1] + r_base;

      IF d = horizon THEN
        v_with90 := r_with;
        v_base90 := r_base;
      END IF;

      days_since_with := days_since_with + 1;
      IF power(1 + (days_since_with / (9.0 * s_with)), -1) <= sp.target_retention THEN
        s_with := engine_success_stability(
          s_with,
          node_row.difficulty,
          'good'::review_grade,
          power(1 + (days_since_with / (9.0 * s_with)), -1)::numeric,
          sp.w1, sp.w2, sp.w3, sp.hard_penalty, sp.easy_bonus
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

  UPDATE profiles
  SET retention_with_recall = round(v_with90 * 100, 2),
      retention_baseline = round(v_base90 * 100, 2),
      memories_saved = v_memories
  WHERE id = p_user;

  RETURN jsonb_build_object(
    'retention_with_recall', round(v_with90 * 100, 1),
    'retention_baseline', round(v_base90 * 100, 1),
    'curve_points', curve,
    'is_projected', v_is_projected,
    'review_days_count', v_review_days,
    'memories_saved', v_memories
  );
END;
$$;

REVOKE ALL ON FUNCTION retention_simulate_rpc(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION retention_simulate_rpc(uuid) TO service_role;
