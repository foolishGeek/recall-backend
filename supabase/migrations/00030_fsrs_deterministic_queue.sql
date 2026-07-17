-- [D-ENG-REC] FSRS scheduling + deterministic due queue; retire heat as ranker.
-- Phase 1–2: published FSRS-6 defaults, learning eligibility, due-first stacks,
-- Drop pool = truly due cards, no comfort→S seed.

SET search_path = public, extensions;

-- Default FSRS-6 weights (open-spaced-repetition / Anki).
-- Indices: w0..w3 init S; w4..w7 difficulty; w8..w10,w15,w16 success S;
-- w11..w14 lapse S; w17..w19 same-day; w20 decay.

CREATE OR REPLACE FUNCTION engine_fsrs_w(p_i integer)
RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (ARRAY[
    0.212, 1.2931, 2.3065, 8.2956,
    6.4133, 0.8334, 3.0194, 0.001,
    1.8722, 0.1666, 0.796,
    1.4835, 0.0614, 0.2629, 1.6483,
    0.6014, 1.8729,
    0.5425, 0.0912, 0.0658,
    0.1542
  ])[p_i + 1]::numeric;
$$;

-- UI difficulty 1..5 ↔ FSRS difficulty 1..10
CREATE OR REPLACE FUNCTION engine_d_to_fsrs(p_d smallint)
RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT least(10.0, greatest(1.0,
    1.0 + (COALESCE(p_d, 3)::numeric - 1.0) * (9.0 / 4.0)
  ));
$$;

CREATE OR REPLACE FUNCTION engine_d_from_fsrs(p_d numeric)
RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT least(5, greatest(1,
    round(1.0 + (COALESCE(p_d, 5.5) - 1.0) * (4.0 / 9.0))::integer
  ))::smallint;
$$;

CREATE OR REPLACE FUNCTION engine_fsrs_factor(p_decay numeric DEFAULT NULL)
RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (power(0.9::numeric, 1.0 / (-COALESCE(p_decay, engine_fsrs_w(20)))) - 1.0)::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_retrievability(
  p_stability numeric,
  p_last_reviewed_at timestamptz,
  p_at timestamptz
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN p_stability IS NULL OR p_last_reviewed_at IS NULL OR p_stability <= 0 THEN 0::numeric
    WHEN p_at < p_last_reviewed_at THEN 1::numeric
    ELSE (
      power(
        1.0 + engine_fsrs_factor() * (
          (extract(epoch FROM (p_at - p_last_reviewed_at)) / 86400.0) / p_stability
        ),
        -engine_fsrs_w(20)
      )
    )::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION engine_interval_days(
  p_stability numeric,
  p_target_retention numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN p_stability IS NULL OR p_stability <= 0 THEN 0::numeric
    WHEN p_target_retention IS NULL OR p_target_retention <= 0 OR p_target_retention >= 1 THEN p_stability
    ELSE (
      (power(p_target_retention, 1.0 / (-engine_fsrs_w(20))) - 1.0)
      / engine_fsrs_factor()
      * p_stability
    )::numeric
  END;
$$;

-- FSRS init stability S0(G) = w[G-1]
CREATE OR REPLACE FUNCTION engine_s0(
  p_grade review_grade,
  p_difficulty smallint
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT greatest(
    0.1,
    CASE p_grade
      WHEN 'again'::review_grade THEN engine_fsrs_w(0)
      WHEN 'hard'::review_grade THEN engine_fsrs_w(1)
      WHEN 'good'::review_grade THEN engine_fsrs_w(2)
      WHEN 'easy'::review_grade THEN engine_fsrs_w(3)
    END
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_fsrs_init_difficulty(p_grade review_grade)
RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT least(10.0, greatest(1.0,
    engine_fsrs_w(4)
    - exp(engine_fsrs_w(5) * (engine_grade_value(p_grade) - 1))
    + 1.0
  ))::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_success_stability(
  p_stability numeric,
  p_difficulty smallint,
  p_grade review_grade,
  p_r numeric,
  p_w1 numeric,
  p_w2 numeric,
  p_w3 numeric,
  p_hard_penalty numeric,
  p_easy_bonus numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  -- FSRS next_recall_stability; legacy w1..w3 / hard_penalty / easy_bonus ignored.
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
  p_w4 numeric,
  p_w5 numeric,
  p_w6 numeric,
  p_w7 numeric,
  p_s_min numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  -- FSRS next_forget_stability; legacy w4..w7 ignored.
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

CREATE OR REPLACE FUNCTION engine_short_term_stability(
  p_stability numeric,
  p_grade review_grade
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT greatest(
    0.1,
    p_stability
      * exp(engine_fsrs_w(17) * (engine_grade_value(p_grade) - 3 + engine_fsrs_w(18)))
      * power(greatest(p_stability, 0.1), -engine_fsrs_w(19))
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_drift_difficulty(
  p_difficulty smallint,
  p_grade review_grade,
  p_w8 numeric
) RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  -- FSRS next_difficulty with linear damping + mean reversion to D0(Easy).
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

-- Heat helper retained for legacy callers; returns 0 (heat retired).
CREATE OR REPLACE FUNCTION engine_heat(
  p_stability numeric,
  p_last_reviewed_at timestamptz,
  p_due_at timestamptz,
  p_priority smallint,
  p_difficulty smallint,
  p_target_retention numeric,
  p_now timestamptz
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT 0::numeric;
$$;

-- No comfort→stability seed; S stays null until first grade.
CREATE OR REPLACE FUNCTION seed_node_stability() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RETURN NEW;
END;
$$;

UPDATE scheduling_params
SET lookahead_hours = 0
WHERE user_id IS NULL AND bucket_id IS NULL AND lookahead_hours = 12;

-- ---------------------------------------------------------------------
-- record_review_rpc — FSRS updates; learning steps unchanged [D-ENG-7]
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
          sp.w4, sp.w5, sp.w6, sp.w7,
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
    d_after := engine_drift_difficulty(d_before, p_grade, sp.w8);
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
        r_before,
        sp.w1, sp.w2, sp.w3,
        sp.hard_penalty,
        sp.easy_bonus
      );
    END IF;
    due_after := reviewed_at + (engine_interval_days(s_after, sp.target_retention)::double precision * interval '1 day');
    d_after := engine_drift_difficulty(d_before, p_grade, sp.w8);
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
        sp.w4, sp.w5, sp.w6, sp.w7,
        sp.s_min
      );
    ELSIF g = 'again'::review_grade THEN
      s_after := engine_s0(g, n_row.difficulty);
    ELSE
      s_after := engine_success_stability(
        COALESCE(n_row.stability, sp.s_min),
        n_row.difficulty,
        g,
        r_before,
        sp.w1, sp.w2, sp.w3,
        sp.hard_penalty,
        sp.easy_bonus
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
-- generate_stack_rpc — deterministic due-first; include learning
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
  SELECT node_id, position, NULL::numeric AS heat_value
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

  INSERT INTO stack_items (stack_id, node_id, position, heat_snapshot)
  SELECT new_stack.id, node_id, position::smallint, NULL
  FROM tmp_stack_selected
  ORDER BY position;

  UPDATE buckets b
  SET cooldown_until = v_now + b.cooling_period,
      updated_at = v_now
  WHERE b.id = ANY(scope_ids)
    AND b.user_id = p_user
    AND b.deleted_at IS NULL;

  RETURN stack_payload_json(new_stack.id) || jsonb_build_object('existing', false);
END;
$$;

CREATE OR REPLACE FUNCTION today_summary_rpc()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  scope_ids uuid[];
  v_now timestamptz := now();
  v_due_count integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  scope_ids := resolve_stack_scope_bucket_ids(p_user, NULL);

  IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object(
      'due_count', 0,
      'aggregate_heat', 0,
      'hot_count', 0,
      'warm_count', 0,
      'cool_count', 0
    );
  END IF;

  SELECT count(*)::integer INTO v_due_count
  FROM nodes n
  JOIN buckets b ON b.id = n.bucket_id
  WHERE n.bucket_id = ANY(scope_ids)
    AND n.deleted_at IS NULL
    AND n.state <> 'leech'::node_state
    AND (b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
    AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
    AND n.due_at IS NOT NULL
    AND n.due_at <= v_now;

  RETURN jsonb_build_object(
    'due_count', COALESCE(v_due_count, 0),
    'aggregate_heat', 0,
    'hot_count', 0,
    'warm_count', 0,
    'cool_count', 0
  );
END;
$$;

CREATE OR REPLACE FUNCTION due_pool_preview_rpc(p_limit integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  scope_ids uuid[];
  v_now timestamptz := now();
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  scope_ids := resolve_stack_scope_bucket_ids(p_user, NULL);

  IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_json ORDER BY sort_due ASC NULLS LAST, sort_priority DESC, sort_id)
      FROM (
        SELECT jsonb_build_object(
          'node_id', n.id,
          'title', n.title,
          'bucket_id', n.bucket_id,
          'bucket_name', b.name,
          'priority', n.priority,
          'difficulty', n.difficulty,
          'due_at', n.due_at,
          'heat', 0
        ) AS row_json,
        n.due_at AS sort_due,
        n.priority AS sort_priority,
        n.id AS sort_id
        FROM nodes n
        JOIN buckets b ON b.id = n.bucket_id
        WHERE n.bucket_id = ANY(scope_ids)
          AND n.deleted_at IS NULL
          AND n.state <> 'leech'::node_state
          AND (b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
          AND (
            (
              n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
              AND n.due_at IS NOT NULL
              AND n.due_at <= v_now
            )
            OR n.state = 'new'::node_state
          )
        ORDER BY
          CASE WHEN n.state = 'new'::node_state THEN 1 ELSE 0 END,
          n.due_at ASC NULLS LAST,
          n.priority DESC,
          n.id
        LIMIT p_limit
      ) sub
    ),
    '[]'::jsonb
  );
END;
$$;

CREATE OR REPLACE FUNCTION review_ahead_count_rpc()
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
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
  v_now timestamptz := now();
  v_count integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RETURN 0;
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

  scope_ids := resolve_stack_scope_bucket_ids(p_user, NULL);

  IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  SELECT count(*) INTO new_today
  FROM reviews r
  WHERE r.user_id = p_user
    AND r.stability_before IS NULL
    AND (r.reviewed_at AT TIME ZONE tz)::date = (v_now AT TIME ZONE tz)::date;

  new_budget := GREATEST(0, LEAST(sp.max_new_per_stack, sp.new_per_day - COALESCE(new_today, 0)));

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
        WHEN n.state IN ('learning'::node_state, 'relearning'::node_state) THEN 0
        WHEN n.state = 'review'::node_state THEN 1
        ELSE 2
      END AS rank_group
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
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
    SELECT * FROM raw
    WHERE state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
  ),
  combined AS (
    SELECT node_id, bucket_id, rank_group, due_at, priority, bucket_cap FROM due_cards
    UNION ALL
    SELECT node_id, bucket_id, rank_group, due_at, priority, bucket_cap FROM new_limited
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
  )
  SELECT count(*)::integer INTO v_count
  FROM (
    SELECT node_id,
           row_number() OVER (
             ORDER BY rank_group ASC, due_at ASC NULLS LAST, priority DESC, node_id
           ) AS rn
    FROM bucket_capped
  ) ranked
  WHERE rn <= effective_n;

  RETURN COALESCE(v_count, 0);
END;
$$;

-- Drop pool: truly due learning/review/relearning only (no new inflation).
CREATE OR REPLACE FUNCTION compute_due_candidates()
RETURNS TABLE (
  user_id uuid,
  dedupe_key text,
  due_pool_size integer,
  tokens jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_now timestamptz := now();
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT
      p.id AS uid,
      COALESCE(p.timezone, 'UTC') AS tz,
      p.drop_frequency,
      p.quiet_hours_start,
      p.quiet_hours_end,
      (p.id::text || ':' || ((v_now AT TIME ZONE COALESCE(p.timezone, 'UTC'))::date)::text) AS dkey
    FROM profiles p
    WHERE p.push_opt_in = true
  )
  SELECT
    c.uid,
    c.dkey,
    pool.due_pool_size,
    tok.tokens
  FROM candidates c
  CROSS JOIN LATERAL (SELECT * FROM engine_params(c.uid, NULL)) sp
  CROSS JOIN LATERAL (
    SELECT array_agg(b.id) AS scope_ids
    FROM active_buckets_for_user(c.uid) b
    WHERE b.cooldown_until IS NULL OR b.cooldown_until <= v_now
  ) scope
  CROSS JOIN LATERAL (
    SELECT
      count(*)::integer AS due_pool_size,
      COALESCE(bool_or(
        n.priority = 5 AND n.due_at IS NOT NULL AND n.due_at <= v_now
      ), false) AS overdue_p5
    FROM nodes n
    WHERE scope.scope_ids IS NOT NULL
      AND n.bucket_id = ANY(scope.scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
      AND n.due_at IS NOT NULL
      AND n.due_at <= v_now
  ) pool
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('platform', dt.platform, 'token', dt.token)) AS tokens
    FROM device_tokens dt
    WHERE dt.user_id = c.uid
  ) tok
  WHERE NOT is_in_quiet_hours(v_now, c.tz, c.quiet_hours_start, c.quiet_hours_end)
    AND scope.scope_ids IS NOT NULL
    AND tok.tokens IS NOT NULL
    AND (pool.due_pool_size >= sp.drop_threshold OR pool.overdue_p5)
    AND (
      SELECT count(*)
      FROM notification_events ne
      WHERE ne.user_id = c.uid
        AND ne.type = 'sent'::notification_event_type
        AND ne.created_at >= v_now - interval '7 days'
    ) < CASE c.drop_frequency
          WHEN 'weekly' THEN app_config_int('drop_budget_weekly', 1)
          WHEN '3xwk' THEN app_config_int('drop_budget_3xwk', 3)
          ELSE app_config_int('drop_budget_daily', 7)
        END
    AND NOT EXISTS (
      SELECT 1
      FROM notification_events ne2
      WHERE ne2.dedupe_key = c.dkey
        AND ne2.type = 'sent'::notification_event_type
    );
END;
$$;

REVOKE ALL ON FUNCTION compute_due_candidates() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION compute_due_candidates() TO service_role;
