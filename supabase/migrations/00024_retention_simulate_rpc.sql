-- Sprint 21 · Retention simulation (server-authoritative, engine-backed).
-- Powers the Insights premium retention hero + 90-day forgetting curve and the
-- You-tab memory simulation (S22). Mobile renders + animates only; all curve,
-- hero, and memories_saved math lives here on top of the same FSRS-inspired
-- engine_retrievability / engine_success_stability used by scheduling [S04].
--
-- Two diverging lines over a 90-day horizon, both starting from each node's
-- CURRENT state at day 0 so they share a common origin and diverge (matches
-- Recall Insights.dc.html):
--   with_recall — forward sim that does a `good` review whenever retrievability
--                 decays to target_retention (spaced repetition keeps R high).
--   baseline    — same starting stability, but ZERO further reviews: pure
--                 power-law decay ("what you'd lose if you stopped" / Ebbinghaus).
--
-- memories_saved is the loss-aversion anchor: nodes whose day-90 with-Recall
-- retrievability beats the no-review baseline by a meaningful margin. Persisted
-- with a GREATEST guard so the headline number never visibly regresses between
-- visits. Tie-breaker: CANON-DECISIONS.md.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- retention_simulate_rpc — EF-only (service role). The caller
-- (retention-simulate EF) has already verified premium + ownership and passes
-- the resolved user id. SECURITY DEFINER + explicit owner arg; never trusts RLS.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retention_simulate_rpc(p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  sp scheduling_params;
  horizon constant int := 90;
  n record;
  d int;
  s_with numeric;          -- evolving stability on the reviewed track
  s_base numeric;          -- fixed starting stability on the no-review track
  days_since_with numeric; -- days since last (simulated) review
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

  -- Per-day accumulators for the averaged portfolio curve (indices 1..horizon+1).
  sum_with := array_fill(0::numeric, ARRAY[horizon + 1]);
  sum_base := array_fill(0::numeric, ARRAY[horizon + 1]);

  SELECT count(DISTINCT activity_date) INTO v_review_days
  FROM daily_activity WHERE user_id = p_user;
  v_review_days := COALESCE(v_review_days, 0);
  v_is_projected := v_review_days < 7;

  -- Active portfolio: all non-deleted nodes in the user's non-deleted buckets.
  -- (Premium-only EF, so every owned bucket is active.) Bounded for cost; this
  -- EF is excluded from the CRUD latency budget.
  FOR n IN
    SELECT n.id,
           GREATEST(
             COALESCE(n.stability, engine_stability_from_comfort(n.comfort, sp.comfort_k)),
             sp.s_min
           ) AS stability,
           n.difficulty
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE b.user_id = p_user
      AND n.deleted_at IS NULL
      AND b.deleted_at IS NULL
    LIMIT 1000
  LOOP
    node_count := node_count + 1;
    s_with := n.stability;
    s_base := n.stability;
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

      -- Advance the reviewed track by one day; when R decays to the target
      -- retention, simulate a `good` review (engine success-stability path).
      days_since_with := days_since_with + 1;
      IF power(1 + (days_since_with / (9.0 * s_with)), -1) <= sp.target_retention THEN
        s_with := engine_success_stability(
          s_with,
          n.difficulty,
          'good'::review_grade,
          power(1 + (days_since_with / (9.0 * s_with)), -1)::numeric,
          sp.w1, sp.w2, sp.w3, sp.hard_penalty, sp.easy_bonus
        );
        days_since_with := 0;
      END IF;
    END LOOP;

    -- Loss-aversion anchor: this node is "saved" when spaced repetition keeps
    -- it meaningfully above where it would have decayed with no reviews.
    IF (COALESCE(v_with90, 0) - COALESCE(v_base90, 0)) >= 0.15 THEN
      v_memories := v_memories + 1;
    END IF;
  END LOOP;

  -- Build the day-by-day curve (averaged across the portfolio, 0..1 fractions).
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

  -- Monotonic guard: the headline "memories saved" must never visibly regress.
  SELECT memories_saved INTO v_prev_memories FROM profiles WHERE id = p_user;
  v_memories := GREATEST(v_memories, COALESCE(v_prev_memories, 0));

  -- Cache hero numbers + memories on the profile so S22 / offline can fall back
  -- to them when the EF is unavailable.
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
