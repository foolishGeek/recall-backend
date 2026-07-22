-- Drop retired heat plumbing and unused legacy SM-2 weight columns.
--
-- FSRS-6 (00030) hardcodes w0..w20 in engine_fsrs_w(); scheduling_params.w1..w8
-- were only still copied for row-compat and passed into helpers that ignore them.
-- Heat ranking is gone (deterministic due queue); stack selects still projected a
-- NULL heat_value and wrote NULL heat_snapshot. node_heat_pct always returned 0.
--
-- This migration:
--   1. Adds slim FSRS helper overloads (no ignored w / hard_penalty / easy_bonus)
--   2. Retargets record / preview / retention / stack builders
--   3. Drops old helper overloads + engine_heat / node_heat_pct
--   4. Drops scheduling_params.w1..w8 and stack_items.heat_snapshot

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Slim FSRS helpers (new overloads; old signatures dropped below)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION engine_success_stability(
  p_stability numeric,
  p_difficulty smallint,
  p_grade review_grade,
  p_r numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (
    p_stability * (
      1.0
      + exp(engine_fsrs_w(8))
      * (11.0 - engine_d_to_fsrs(p_difficulty))
      * power(greatest(p_stability, 0.1), -engine_fsrs_w(9))
      * (exp(engine_fsrs_w(10) * (1.0 - COALESCE(p_r, 0))) - 1.0)
      * CASE p_grade
          WHEN 'hard'::review_grade THEN engine_fsrs_w(15)
          ELSE 1.0
        END
      * CASE p_grade
          WHEN 'easy'::review_grade THEN engine_fsrs_w(16)
          ELSE 1.0
        END
    )
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_lapse_stability(
  p_stability numeric,
  p_difficulty smallint,
  p_r numeric,
  p_s_min numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT least(
    greatest(p_stability, 0.1),
    greatest(
      COALESCE(p_s_min, 0.1),
      engine_fsrs_w(11)
        * power(engine_d_to_fsrs(p_difficulty), -engine_fsrs_w(12))
        * (power(COALESCE(p_stability, 0.1) + 1.0, engine_fsrs_w(13)) - 1.0)
        * exp(engine_fsrs_w(14) * (1.0 - COALESCE(p_r, 0)))
    )
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_drift_difficulty(
  p_difficulty smallint,
  p_grade review_grade
) RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  WITH base AS (
    SELECT engine_d_to_fsrs(p_difficulty) AS d,
           engine_grade_value(p_grade) AS g
  ),
  stepped AS (
    SELECT
      d + ((-engine_fsrs_w(6) * (g - 3)) * ((10.0 - d) / 9.0)) AS next_d
    FROM base
  ),
  reverted AS (
    SELECT
      engine_fsrs_w(7) * engine_fsrs_init_difficulty('easy'::review_grade)
      + (1.0 - engine_fsrs_w(7)) * next_d AS d_fsrs
    FROM stepped
  )
  SELECT engine_d_from_fsrs(least(10.0, greatest(1.0, d_fsrs)))
  FROM reverted;
$$;

-- ---------------------------------------------------------------------
-- record_review_rpc — call slim helpers only
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

  SELECT * INTO r_row
  FROM reviews
  WHERE user_id = p_user AND idempotency_key = p_key;

  IF FOUND THEN
    SELECT n.* INTO n_row
    FROM nodes n
    WHERE n.id = r_row.node_id;

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
  RETURNING * INTO r_row;

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
-- preview_due_interval_rpc
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION preview_due_interval_rpc(node_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  n_row nodes%ROWTYPE;
  sp scheduling_params%ROWTYPE;
  g review_grade;
  r_before numeric;
  s_after numeric;
  days numeric;
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
  r_before := engine_retrievability(n_row.stability, n_row.last_reviewed_at, now());

  FOREACH g IN ARRAY ARRAY['again'::review_grade, 'hard'::review_grade, 'good'::review_grade, 'easy'::review_grade]
  LOOP
    IF n_row.state = 'new'::node_state OR n_row.stability IS NULL THEN
      s_after := engine_s0(g, n_row.difficulty);
    ELSIF g = 'again'::review_grade AND n_row.state = 'review'::node_state THEN
      s_after := engine_lapse_stability(
        COALESCE(n_row.stability, sp.s_min),
        n_row.difficulty,
        r_before,
        sp.s_min
      );
    ELSIF g = 'again'::review_grade THEN
      s_after := engine_s0(g, n_row.difficulty);
    ELSE
      s_after := engine_success_stability(
        COALESCE(n_row.stability, sp.s_min),
        n_row.difficulty,
        g,
        r_before
      );
    END IF;

    days := engine_interval_days(s_after, sp.target_retention);
    out := out || jsonb_build_object(
      g::text,
      jsonb_build_object('label', engine_interval_label(days), 'interval_days', days)
    );
  END LOOP;

  RETURN out;
END;
$$;

-- ---------------------------------------------------------------------
-- retention_simulate_rpc — slim success_stability call
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
           GREATEST(
             COALESCE(nd.stability, engine_stability_from_comfort(nd.comfort, sp.comfort_k)),
             sp.s_min
           ) AS stability,
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

-- ---------------------------------------------------------------------
-- generate_stack_rpc — no heat_value / heat_snapshot
-- (00047 body + heat columns removed)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_stack_rpc(
  scope_bucket_ids uuid[] DEFAULT NULL,
  ahead boolean DEFAULT false,
  seed integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  sp scheduling_params%ROWTYPE;
  t subscription_tier;
  tz text;
  effective_n integer;
  free_cap integer := app_config_int('session_size_free', 8);
  new_today integer;
  new_budget integer;
  scope_ids uuid[];
  active_stack stacks%ROWTYPE;
  new_stack stacks%ROWTYPE;
  selected_count integer;
  v_now timestamptz := now();
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT s.* INTO active_stack
  FROM stacks s
  WHERE s.user_id = p_user AND s.status = 'active'
  LIMIT 1;

  IF active_stack.id IS NOT NULL THEN
    RETURN stack_payload_json(active_stack.id) || jsonb_build_object('existing', true);
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RAISE EXCEPTION 'invalid_input: scheduling_params missing' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(sub.tier, 'free'::subscription_tier), COALESCE(p.timezone, 'UTC')
    INTO t, tz
  FROM profiles p
  LEFT JOIN subscriptions sub ON sub.user_id = p.id
  WHERE p.id = p_user;
  t := COALESCE(t, 'free'::subscription_tier);
  tz := COALESCE(tz, 'UTC');

  effective_n := COALESCE((SELECT session_size_override FROM profiles WHERE id = p_user), sp.session_size);
  IF t <> 'premium'::subscription_tier THEN
    effective_n := LEAST(effective_n, free_cap);
  END IF;

  scope_ids := resolve_stack_scope_bucket_ids(p_user, scope_bucket_ids);

  IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object('stack', NULL, 'items', '[]'::jsonb, 'reason', 'empty_scope');
  END IF;

  SELECT count(*) INTO new_today
  FROM reviews r
  WHERE r.user_id = p_user
    AND r.stability_before IS NULL
    AND (r.reviewed_at AT TIME ZONE tz)::date = (v_now AT TIME ZONE tz)::date;

  new_budget := GREATEST(0, LEAST(sp.max_new_per_stack, sp.new_per_day - COALESCE(new_today, 0)));

  DROP TABLE IF EXISTS pg_temp.tmp_stack_selected;

  CREATE TEMP TABLE tmp_stack_selected ON COMMIT DROP AS
  WITH raw AS (
    SELECT
      n.id AS node_id,
      n.bucket_id,
      n.state,
      n.priority,
      n.due_at,
      n.created_at,
      COALESCE(b.daily_cap, sp.max_per_bucket) AS bucket_cap,
      CASE
        WHEN n.state IN ('learning'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND (ahead OR n.due_at <= v_now) THEN 0
        WHEN n.state = 'review'::node_state
          AND n.due_at IS NOT NULL
          AND (ahead OR n.due_at <= v_now) THEN 1
        ELSE 2
      END AS rank_group
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.sr_enabled
      AND n.state <> 'leech'::node_state
      AND (ahead OR b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND (ahead OR n.due_at <= v_now)
        )
      )
  ),
  new_limited AS (
    SELECT *
    FROM (
      SELECT raw.*, row_number() OVER (
        ORDER BY priority DESC, created_at ASC, node_id
      ) AS new_rn
      FROM raw
      WHERE state = 'new'::node_state
    ) x
    WHERE new_rn <= new_budget
  ),
  due_cards AS (
    SELECT *
    FROM raw
    WHERE state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
  ),
  combined AS (
    SELECT node_id, bucket_id, state, priority, due_at, bucket_cap, rank_group
    FROM due_cards
    UNION ALL
    SELECT node_id, bucket_id, state, priority, due_at, bucket_cap, rank_group
    FROM new_limited
  ),
  bucket_capped AS (
    SELECT *
    FROM (
      SELECT combined.*,
             row_number() OVER (
               PARTITION BY bucket_id
               ORDER BY rank_group ASC, due_at ASC NULLS LAST, priority DESC, node_id
             ) AS bucket_rn
      FROM combined
    ) x
    WHERE bucket_rn <= bucket_cap
  ),
  final_ranked AS (
    SELECT *,
           row_number() OVER (
             ORDER BY rank_group ASC, due_at ASC NULLS LAST, priority DESC, node_id
           ) - 1 AS position
    FROM bucket_capped
  )
  SELECT node_id, position
  FROM final_ranked
  WHERE position < effective_n
  ORDER BY position;

  SELECT count(*) INTO selected_count FROM tmp_stack_selected;

  IF selected_count = 0 THEN
    RETURN jsonb_build_object('stack', NULL, 'items', '[]'::jsonb, 'reason', 'empty_pool');
  END IF;

  INSERT INTO stacks (user_id, scope)
  VALUES (p_user, jsonb_build_object('bucket_ids', scope_ids))
  RETURNING * INTO new_stack;

  INSERT INTO stack_items (stack_id, node_id, position)
  SELECT new_stack.id, node_id, position::smallint
  FROM tmp_stack_selected
  ORDER BY position;

  RETURN stack_payload_json(new_stack.id) || jsonb_build_object('existing', false);
END;
$$;

-- ---------------------------------------------------------------------
-- build_stack_from_nodes_rpc — no heat
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION build_stack_from_nodes_rpc(p_node_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  active_stack stacks%ROWTYPE;
  new_stack stacks%ROWTYPE;
  sel_count integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT s.* INTO active_stack
  FROM stacks s
  WHERE s.user_id = p_user AND s.status = 'active'
  LIMIT 1;

  IF active_stack.id IS NOT NULL THEN
    RETURN stack_payload_json(active_stack.id) || jsonb_build_object('existing', true);
  END IF;

  IF p_node_ids IS NULL OR array_length(p_node_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('stack', NULL, 'items', '[]'::jsonb, 'reason', 'empty_pool');
  END IF;

  DROP TABLE IF EXISTS pg_temp.tmp_missed_nodes;
  CREATE TEMP TABLE tmp_missed_nodes ON COMMIT DROP AS
  WITH input AS (
    SELECT id, ord FROM unnest(p_node_ids) WITH ORDINALITY AS u(id, ord)
  ),
  owned AS (
    SELECT DISTINCT ON (n.id)
           n.id AS node_id,
           i.ord
    FROM input i
    JOIN nodes n ON n.id = i.id
    JOIN buckets b ON b.id = n.bucket_id
    WHERE b.user_id = p_user
      AND n.deleted_at IS NULL
      AND b.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
    ORDER BY n.id, i.ord
  )
  SELECT node_id,
         (row_number() OVER (ORDER BY ord) - 1)::smallint AS position
  FROM owned;

  SELECT count(*) INTO sel_count FROM tmp_missed_nodes;
  IF sel_count = 0 THEN
    RETURN jsonb_build_object('stack', NULL, 'items', '[]'::jsonb, 'reason', 'empty_pool');
  END IF;

  INSERT INTO stacks (user_id, scope)
  VALUES (p_user, jsonb_build_object('source', 'quiz_missed'))
  RETURNING * INTO new_stack;

  INSERT INTO stack_items (stack_id, node_id, position)
  SELECT new_stack.id, node_id, position
  FROM tmp_missed_nodes
  ORDER BY position;

  RETURN stack_payload_json(new_stack.id) || jsonb_build_object('existing', false);
END;
$$;

-- ---------------------------------------------------------------------
-- set_scheduling_prefs_rpc — stop copying dead w1..w8
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
    lookahead_hours, temperature, drop_threshold, leech_lapse_threshold
  ) VALUES (
    p_user, p_bucket_id, v_clamped,
    parent.s_min, parent.comfort_k, parent.hard_penalty, parent.easy_bonus,
    parent.new_per_day, parent.session_size, parent.max_new_per_stack,
    parent.max_per_bucket, parent.lookahead_hours, parent.temperature,
    parent.drop_threshold, parent.leech_lapse_threshold
  )
  ON CONFLICT (user_id, bucket_id)
  DO UPDATE SET target_retention = EXCLUDED.target_retention;

  RETURN get_scheduling_prefs_rpc(p_bucket_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Drop old overloads + heat RPCs, then columns
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS engine_success_stability(numeric, smallint, review_grade, numeric, numeric, numeric, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS engine_lapse_stability(numeric, smallint, numeric, numeric, numeric, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS engine_drift_difficulty(smallint, review_grade, numeric);
DROP FUNCTION IF EXISTS node_heat_pct(uuid);
DROP FUNCTION IF EXISTS engine_heat(numeric, timestamptz, timestamptz, smallint, smallint, numeric, timestamptz);

ALTER TABLE scheduling_params
  DROP COLUMN IF EXISTS w1,
  DROP COLUMN IF EXISTS w2,
  DROP COLUMN IF EXISTS w3,
  DROP COLUMN IF EXISTS w4,
  DROP COLUMN IF EXISTS w5,
  DROP COLUMN IF EXISTS w6,
  DROP COLUMN IF EXISTS w7,
  DROP COLUMN IF EXISTS w8;

ALTER TABLE stack_items
  DROP COLUMN IF EXISTS heat_snapshot;
