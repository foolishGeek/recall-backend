-- Engine hardening (Phase 1). Three correctness fixes on the final (00053)
-- review path — no behavioural change to the FSRS-6 math itself:
--
--   1. record_review_rpc idempotency race: the duplicate check ran BEFORE the
--      node row lock, so two concurrent offline replays with the same key could
--      both pass it, then the second double-applied the grade and hit a raw
--      UNIQUE violation. Now we re-check while holding the node lock (concurrent
--      same-key requests serialize on it) and the insert is conflict-safe.
--
--   2. preview_due_interval_rpc lied: it always showed engine_interval_days for
--      every grade, so "Again" advertised e.g. "+3d" while record_review_rpc
--      actually reschedules it as a learning step (~10 min). It now mirrors
--      record_review_rpc exactly (first-review again/hard → learning step;
--      any again → learning step; same-day → short-term stability), so the
--      +10m / today / +3d captions equal what the server will schedule.
--
--   3. retention_simulate_rpc overstated retention by seeding never-reviewed
--      cards from comfort→stability (contradicts the live engine, which starts
--      new cards at s0/s_min). Never-reviewed cards now seed at sp.s_min so the
--      "memories saved" number stays honest.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- 1. record_review_rpc — race-safe idempotency
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_review_rpc(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  p_node uuid;
  p_stack uuid;
  p_quiz uuid;
  p_grade review_grade;
  p_source review_source;
  p_response_ms integer;
  p_key text;
  p_client_ts timestamptz;
  n_row nodes%ROWTYPE;
  r_row reviews%ROWTYPE;
  sp scheduling_params%ROWTYPE;
  tz text;
  reviewed_at timestamptz := now();
  same_day boolean := false;
  first_review boolean := false;
  r_before numeric;
  r_after numeric;
  s_before numeric;
  s_after numeric;
  d_before smallint;
  d_after smallint;
  c_before smallint;
  c_after smallint;
  due_before timestamptz;
  due_after timestamptz;
  new_state node_state;
  new_reps integer;
  new_lapses integer;
  learning_minutes integer := app_config_int('learning_step_minutes', 10);
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  p_node := (payload->>'node_id')::uuid;
  p_stack := NULLIF(payload->>'stack_id', '')::uuid;
  p_quiz := NULLIF(payload->>'quiz_attempt_id', '')::uuid;
  p_grade := (payload->>'grade')::review_grade;
  p_source := COALESCE(NULLIF(payload->>'source', '')::review_source, 'stack'::review_source);
  p_response_ms := COALESCE((payload->>'response_ms')::integer, 0);
  p_key := NULLIF(payload->>'idempotency_key', '');
  p_client_ts := NULLIF(payload->>'client_timestamp', '')::timestamptz;

  IF p_key IS NULL THEN
    RAISE EXCEPTION 'invalid_input: idempotency_key required' USING ERRCODE = '22023';
  END IF;
  IF p_response_ms < 0 THEN
    RAISE EXCEPTION 'invalid_input: response_ms must be >= 0' USING ERRCODE = '22023';
  END IF;

  -- Fast path: obvious replay (no lock needed).
  SELECT * INTO r_row
  FROM reviews
  WHERE user_id = p_user AND idempotency_key = p_key;

  IF FOUND THEN
    SELECT n.* INTO n_row FROM nodes n WHERE n.id = r_row.node_id;
    RETURN jsonb_build_object('review', to_jsonb(r_row), 'node', to_jsonb(n_row), 'duplicate', true);
  END IF;

  SELECT n.* INTO n_row
  FROM nodes n
  JOIN buckets b ON b.id = n.bucket_id
  WHERE n.id = p_node
    AND b.user_id = p_user
    AND n.deleted_at IS NULL
    AND b.deleted_at IS NULL
  FOR UPDATE OF n;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- Race guard: a same-key replay may have committed while we waited on the
  -- node lock. Concurrent same-key requests target the same node and serialize
  -- on this lock, so re-checking here (holding the lock) prevents a double-apply
  -- and the raw UNIQUE(idempotency_key) violation the old order could throw.
  SELECT * INTO r_row
  FROM reviews
  WHERE user_id = p_user AND idempotency_key = p_key;

  IF FOUND THEN
    RETURN jsonb_build_object('review', to_jsonb(r_row), 'node', to_jsonb(n_row), 'duplicate', true);
  END IF;

  SELECT COALESCE(timezone, 'UTC') INTO tz
  FROM profiles
  WHERE id = p_user;
  tz := COALESCE(tz, 'UTC');

  SELECT * INTO sp FROM engine_params(p_user, n_row.bucket_id);
  IF sp.id IS NULL THEN
    RAISE EXCEPTION 'invalid_input: scheduling_params missing' USING ERRCODE = '22023';
  END IF;

  s_before := n_row.stability;
  d_before := n_row.difficulty;
  c_before := n_row.comfort;
  due_before := n_row.due_at;
  r_before := engine_retrievability(n_row.stability, n_row.last_reviewed_at, reviewed_at);
  first_review := (n_row.state = 'new'::node_state OR n_row.stability IS NULL);
  same_day := (
    n_row.last_reviewed_at IS NOT NULL
    AND (n_row.last_reviewed_at AT TIME ZONE tz)::date = (reviewed_at AT TIME ZONE tz)::date
  );

  new_state := n_row.state;
  new_reps := n_row.reps + 1;
  new_lapses := n_row.lapses;
  s_after := n_row.stability;

  IF first_review THEN
    s_after := engine_s0(p_grade, d_before);
    d_after := engine_d_from_fsrs(engine_fsrs_init_difficulty(p_grade));
    IF p_grade IN ('good'::review_grade, 'easy'::review_grade) THEN
      new_state := 'review'::node_state;
      due_after := reviewed_at + (engine_interval_days(s_after, sp.target_retention)::double precision * interval '1 day');
    ELSE
      new_state := 'learning'::node_state;
      due_after := reviewed_at + (learning_minutes * interval '1 minute');
    END IF;
    IF p_grade = 'again'::review_grade THEN
      new_lapses := new_lapses + 1;
    END IF;
  ELSIF p_grade = 'again'::review_grade THEN
    new_lapses := new_lapses + 1;
    IF n_row.state = 'review'::node_state THEN
      new_state := 'relearning'::node_state;
      IF same_day THEN
        s_after := engine_short_term_stability(COALESCE(n_row.stability, sp.s_min), p_grade);
      ELSE
        s_after := engine_lapse_stability(
          COALESCE(n_row.stability, sp.s_min),
          d_before,
          r_before,
          sp.s_min
        );
      END IF;
    ELSE
      new_state := 'learning'::node_state;
      s_after := CASE
        WHEN same_day THEN engine_short_term_stability(COALESCE(n_row.stability, sp.s_min), p_grade)
        ELSE engine_s0(p_grade, d_before)
      END;
    END IF;
    due_after := reviewed_at + (learning_minutes * interval '1 minute');
    d_after := engine_drift_difficulty(d_before, p_grade);
  ELSE
    IF n_row.state IN ('learning'::node_state, 'relearning'::node_state) THEN
      new_state := 'review'::node_state;
    END IF;

    IF same_day THEN
      s_after := engine_short_term_stability(COALESCE(n_row.stability, sp.s_min), p_grade);
    ELSE
      s_after := engine_success_stability(
        COALESCE(n_row.stability, sp.s_min),
        d_before,
        p_grade,
        r_before
      );
    END IF;
    due_after := reviewed_at + (engine_interval_days(s_after, sp.target_retention)::double precision * interval '1 day');
    d_after := engine_drift_difficulty(d_before, p_grade);
  END IF;

  IF new_lapses >= sp.leech_lapse_threshold THEN
    new_state := 'leech'::node_state;
  END IF;
  c_after := engine_comfort(s_after, sp.comfort_k);

  UPDATE nodes
  SET stability = s_after,
      difficulty = d_after,
      comfort = c_after,
      last_reviewed_at = reviewed_at,
      due_at = due_after,
      reps = new_reps,
      lapses = new_lapses,
      state = new_state,
      last_grade = p_grade,
      last_response_ms = p_response_ms,
      updated_at = reviewed_at
  WHERE id = n_row.id
  RETURNING * INTO n_row;

  r_after := engine_retrievability(n_row.stability, n_row.last_reviewed_at, reviewed_at);

  INSERT INTO reviews (
    user_id, node_id, stack_id, quiz_attempt_id, source, idempotency_key, grade,
    stability_before, stability_after, difficulty_before, difficulty_after,
    comfort_before, comfort_after, retrievability_before, retrievability_after,
    due_before, due_after, response_ms, reviewed_at, client_timestamp
  )
  VALUES (
    p_user, n_row.id, p_stack, p_quiz, p_source, p_key, p_grade,
    s_before, s_after, d_before, d_after,
    c_before, c_after, r_before, r_after,
    due_before, due_after, p_response_ms, reviewed_at, p_client_ts
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING * INTO r_row;

  IF r_row.id IS NULL THEN
    -- Belt-and-suspenders: key already used (pathological same-key/other-node).
    -- Return the existing row rather than a raw unique-violation.
    SELECT * INTO r_row FROM reviews WHERE idempotency_key = p_key;
    RETURN jsonb_build_object('review', to_jsonb(r_row), 'node', to_jsonb(n_row), 'duplicate', true);
  END IF;

  IF p_stack IS NOT NULL THEN
    UPDATE stack_items si
    SET reviewed = true
    FROM stacks s
    WHERE si.stack_id = s.id
      AND si.stack_id = p_stack
      AND si.node_id = n_row.id
      AND s.user_id = p_user;
  END IF;

  RETURN jsonb_build_object('review', to_jsonb(r_row), 'node', to_jsonb(n_row), 'duplicate', false);
END;
$$;

-- ---------------------------------------------------------------------
-- 2. preview_due_interval_rpc — mirror record_review_rpc exactly
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION preview_due_interval_rpc(node_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  n_row nodes%ROWTYPE;
  sp scheduling_params%ROWTYPE;
  g review_grade;
  tz text;
  reviewed_at timestamptz := now();
  same_day boolean := false;
  first_review boolean := false;
  r_before numeric;
  s_after numeric;
  days numeric;
  is_learning_step boolean;
  learning_minutes integer := app_config_int('learning_step_minutes', 10);
  lbl text;
  out jsonb := '{}'::jsonb;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT n.* INTO n_row
  FROM nodes n
  JOIN buckets b ON b.id = n.bucket_id
  WHERE n.id = node_id
    AND b.user_id = p_user
    AND n.deleted_at IS NULL
    AND b.deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, n_row.bucket_id);

  SELECT COALESCE(timezone, 'UTC') INTO tz FROM profiles WHERE id = p_user;
  tz := COALESCE(tz, 'UTC');

  r_before := engine_retrievability(n_row.stability, n_row.last_reviewed_at, reviewed_at);
  first_review := (n_row.state = 'new'::node_state OR n_row.stability IS NULL);
  same_day := (
    n_row.last_reviewed_at IS NOT NULL
    AND (n_row.last_reviewed_at AT TIME ZONE tz)::date = (reviewed_at AT TIME ZONE tz)::date
  );

  FOREACH g IN ARRAY ARRAY['again'::review_grade, 'hard'::review_grade, 'good'::review_grade, 'easy'::review_grade]
  LOOP
    is_learning_step := false;

    IF first_review THEN
      -- new card: good/easy graduate to review (interval); again/hard → learning step
      s_after := engine_s0(g, n_row.difficulty);
      is_learning_step := g NOT IN ('good'::review_grade, 'easy'::review_grade);
    ELSIF g = 'again'::review_grade THEN
      -- lapse → learning/relearning step (due in learning_minutes, not days)
      IF n_row.state = 'review'::node_state THEN
        s_after := CASE
          WHEN same_day THEN engine_short_term_stability(COALESCE(n_row.stability, sp.s_min), g)
          ELSE engine_lapse_stability(COALESCE(n_row.stability, sp.s_min), n_row.difficulty, r_before, sp.s_min)
        END;
      ELSE
        s_after := CASE
          WHEN same_day THEN engine_short_term_stability(COALESCE(n_row.stability, sp.s_min), g)
          ELSE engine_s0(g, n_row.difficulty)
        END;
      END IF;
      is_learning_step := true;
    ELSE
      -- hard/good/easy on learning/review/relearning → review (interval days)
      s_after := CASE
        WHEN same_day THEN engine_short_term_stability(COALESCE(n_row.stability, sp.s_min), g)
        ELSE engine_success_stability(COALESCE(n_row.stability, sp.s_min), n_row.difficulty, g, r_before)
      END;
      is_learning_step := false;
    END IF;

    IF is_learning_step THEN
      days := learning_minutes / 1440.0;
      lbl := CASE
        WHEN learning_minutes < 60 THEN learning_minutes::text || 'm'
        ELSE round(learning_minutes / 60.0)::text || 'h'
      END;
    ELSE
      days := engine_interval_days(s_after, sp.target_retention);
      lbl := engine_interval_label(days);
    END IF;

    out := out || jsonb_build_object(
      g::text,
      jsonb_build_object('label', lbl, 'interval_days', days)
    );
  END LOOP;

  RETURN out;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. retention_simulate_rpc — honest seed for never-reviewed cards
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
           -- Honest seed: reviewed cards use their measured stability; cards the
           -- user has never reviewed start at the engine floor (s_min), NOT a
           -- comfort→stability guess (which the live engine never uses and which
           -- inflated "memories saved").
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

REVOKE ALL ON FUNCTION retention_simulate_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION retention_simulate_rpc(uuid) TO service_role;
