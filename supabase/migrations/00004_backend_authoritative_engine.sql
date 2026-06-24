-- Sprint 04 correction: backend-authoritative recall engine.
-- Scheduling, stack generation, preview labels, and next-drop labels are server truth.
-- Mobile may call RPCs and render returned rows only.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Engine helpers (pure SQL, no table writes)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_config_int(p_key text, p_default integer)
RETURNS integer
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE((SELECT (value #>> '{}')::integer FROM app_config WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION engine_params(p_user uuid, p_bucket uuid)
RETURNS scheduling_params
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT sp
  FROM scheduling_params sp
  WHERE (sp.user_id IS NULL AND sp.bucket_id IS NULL)
     OR (p_user IS NOT NULL AND sp.user_id = p_user AND sp.bucket_id IS NULL)
     OR (p_bucket IS NOT NULL AND sp.bucket_id = p_bucket)
  ORDER BY (sp.bucket_id IS NOT NULL) DESC, (sp.user_id IS NOT NULL) DESC
  LIMIT 1;
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
    ELSE power(
      1 + ((extract(epoch FROM (p_at - p_last_reviewed_at)) / 86400.0) / (9.0 * p_stability)),
      -1
    )::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION engine_interval_days(
  p_stability numeric,
  p_target_retention numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (9.0 * p_stability * ((1.0 / p_target_retention) - 1.0))::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_comfort(
  p_stability numeric,
  p_comfort_k numeric
) RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN p_stability IS NULL OR p_stability <= 0 THEN 0::smallint
    ELSE round(100.0 * p_stability / (p_stability + p_comfort_k))::smallint
  END;
$$;

CREATE OR REPLACE FUNCTION engine_stability_from_comfort(
  p_comfort smallint,
  p_comfort_k numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN p_comfort IS NULL OR p_comfort <= 0 THEN 0::numeric
    WHEN p_comfort >= 100 THEN (p_comfort_k * 10.0)::numeric
    ELSE (p_comfort::numeric * p_comfort_k / (100.0 - p_comfort::numeric))::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION engine_s0(
  p_grade review_grade,
  p_difficulty smallint
) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (
    CASE p_grade
      WHEN 'again'::review_grade THEN 0.4
      WHEN 'hard'::review_grade THEN 1.0
      WHEN 'good'::review_grade THEN 3.0
      WHEN 'easy'::review_grade THEN 8.0
    END
    * (1.0 - 0.05 * (COALESCE(p_difficulty, 3)::numeric - 3.0))
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_grade_value(p_grade review_grade)
RETURNS integer
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_grade
    WHEN 'again'::review_grade THEN 1
    WHEN 'hard'::review_grade THEN 2
    WHEN 'good'::review_grade THEN 3
    WHEN 'easy'::review_grade THEN 4
  END;
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
  SELECT (
    p_stability * (
      1.0
      + exp(p_w1)
      * (6.0 - p_difficulty::numeric)
      * power(p_stability, -p_w2)
      * (exp(p_w3 * (1.0 - p_r)) - 1.0)
      * CASE p_grade
          WHEN 'hard'::review_grade THEN p_hard_penalty
          WHEN 'easy'::review_grade THEN p_easy_bonus
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
  SELECT greatest(
    p_s_min,
    p_w4
      * power(p_difficulty::numeric, -p_w5)
      * power(p_stability, p_w6)
      * exp(p_w7 * (1.0 - p_r))
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION engine_drift_difficulty(
  p_difficulty smallint,
  p_grade review_grade,
  p_w8 numeric
) RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT least(
    5,
    greatest(1, round(p_difficulty::numeric - p_w8 * (engine_grade_value(p_grade) - 3))::integer)
  )::smallint;
$$;

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
  WITH vals AS (
    SELECT
      engine_retrievability(p_stability, p_last_reviewed_at, p_now) AS r,
      greatest(engine_interval_days(greatest(COALESCE(p_stability, 0.1), 0.1), p_target_retention), 1.0) AS i_days,
      COALESCE(extract(epoch FROM (p_now - p_due_at)) / 86400.0, 0.0) AS overdue_days
  )
  SELECT (
    least(1.0, greatest(0.0, (overdue_days / i_days) + (1.0 - r)))
    * (1.0 + 0.15 * (COALESCE(p_priority, 3)::numeric - 1.0))
    * (1.0 + 0.12 * (COALESCE(p_difficulty, 3)::numeric - 3.0))
  )::numeric
  FROM vals;
$$;

CREATE OR REPLACE FUNCTION engine_interval_label(p_days numeric)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN p_days < 1 THEN 'today'
    WHEN p_days < 7 THEN '+' || round(p_days)::text || 'd'
    ELSE '+' || round(p_days / 7.0)::text || 'w'
  END;
$$;

CREATE OR REPLACE FUNCTION stack_payload_json(p_stack_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'stack', to_jsonb(s),
    'items', COALESCE(
      (SELECT jsonb_agg(to_jsonb(si) ORDER BY si.position)
       FROM stack_items si
       WHERE si.stack_id = s.id),
      '[]'::jsonb
    )
  )
  FROM stacks s
  WHERE s.id = p_stack_id;
$$;

-- ---------------------------------------------------------------------
-- record_review_rpc: one authoritative write path for reviews + node state.
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
      s_after := engine_lapse_stability(
        COALESCE(n_row.stability, sp.s_min),
        d_before,
        r_before,
        sp.w4,
        sp.w5,
        sp.w6,
        sp.w7,
        sp.s_min
      );
    ELSE
      new_state := 'learning'::node_state;
      s_after := CASE WHEN same_day THEN n_row.stability ELSE engine_s0(p_grade, d_before) END;
    END IF;
    due_after := reviewed_at + (learning_minutes * interval '1 minute');
  ELSE
    IF n_row.state IN ('learning'::node_state, 'relearning'::node_state) THEN
      new_state := 'review'::node_state;
    END IF;

    IF same_day THEN
      s_after := COALESCE(n_row.stability, sp.s_min);
    ELSE
      s_after := engine_success_stability(
        COALESCE(n_row.stability, sp.s_min),
        d_before,
        p_grade,
        r_before,
        sp.w1,
        sp.w2,
        sp.w3,
        sp.hard_penalty,
        sp.easy_bonus
      );
    END IF;
    due_after := reviewed_at + (engine_interval_days(s_after, sp.target_retention)::double precision * interval '1 day');
  END IF;

  d_after := engine_drift_difficulty(d_before, p_grade, sp.w8);
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
-- generate_stack_rpc: one authoritative write path for stacks + items.
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
  provided_count integer;
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

  IF scope_bucket_ids IS NULL THEN
    SELECT array_agg(b.id ORDER BY b.created_at)
      INTO scope_ids
    FROM buckets b
    WHERE b.user_id = p_user AND b.deleted_at IS NULL;
  ELSE
    SELECT count(*) INTO provided_count FROM unnest(scope_bucket_ids);
    SELECT array_agg(b.id ORDER BY b.created_at)
      INTO scope_ids
    FROM buckets b
    WHERE b.user_id = p_user
      AND b.deleted_at IS NULL
      AND b.id = ANY(scope_bucket_ids);
    IF COALESCE(array_length(scope_ids, 1), 0) <> provided_count THEN
      RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
    END IF;
  END IF;

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
      n.created_at,
      COALESCE(b.daily_cap, sp.max_per_bucket) AS bucket_cap,
      engine_heat(n.stability, n.last_reviewed_at, n.due_at, n.priority, n.difficulty, sp.target_retention, v_now) AS heat_value,
      CASE
        WHEN n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.priority = 5
          AND n.due_at < v_now THEN 0
        WHEN n.state IN ('review'::node_state, 'relearning'::node_state) THEN 1
        ELSE 2
      END AS rank_group,
      (
        abs(hashtext(COALESCE(seed, 0)::text || ':' || n.id::text)::bigint)::numeric
        / 2147483647.0
      ) AS jitter
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND (ahead OR b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND (ahead OR n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour'))
        )
      )
  ),
  new_limited AS (
    SELECT *
    FROM (
      SELECT raw.*, row_number() OVER (ORDER BY priority DESC, created_at ASC, jitter ASC) AS new_rn
      FROM raw
      WHERE state = 'new'::node_state
    ) x
    WHERE new_rn <= new_budget
  ),
  due_cards AS (
    SELECT *
    FROM raw
    WHERE state IN ('review'::node_state, 'relearning'::node_state)
  ),
  combined AS (
    SELECT node_id, bucket_id, state, priority, bucket_cap, heat_value, rank_group,
           (power(greatest(heat_value, 0.0001), sp.temperature) + (jitter * 0.0001)) AS score
    FROM due_cards
    UNION ALL
    SELECT node_id, bucket_id, state, priority, bucket_cap, heat_value, rank_group,
           (priority::numeric + (jitter * 0.0001)) AS score
    FROM new_limited
  ),
  bucket_capped AS (
    SELECT *
    FROM (
      SELECT combined.*,
             row_number() OVER (
               PARTITION BY bucket_id
               ORDER BY rank_group ASC, score DESC, heat_value DESC, node_id
             ) AS bucket_rn
      FROM combined
    ) x
    WHERE bucket_rn <= bucket_cap
  ),
  final_ranked AS (
    SELECT *,
           row_number() OVER (
             ORDER BY rank_group ASC, score DESC, heat_value DESC, node_id
           ) - 1 AS position
    FROM bucket_capped
  )
  SELECT node_id, position, heat_value
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
  SELECT new_stack.id, node_id, position::smallint, heat_value
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

-- ---------------------------------------------------------------------
-- Read-only RPCs for UI labels/previews.
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
        sp.w4,
        sp.w5,
        sp.w6,
        sp.w7,
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
        sp.w1,
        sp.w2,
        sp.w3,
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

CREATE OR REPLACE FUNCTION next_drop_time_rpc(bucket_id uuid DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  p profiles%ROWTYPE;
  candidate timestamptz;
  local_now timestamp;
  local_minutes integer;
  start_minutes integer;
  end_minutes integer;
  budget integer;
  sent_count integer;
  min_cooldown timestamptz;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO p FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF bucket_id IS NOT NULL AND NOT owns_bucket(bucket_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  candidate := date_trunc('minute', now());
  candidate := candidate
    + (((15 - (extract(minute FROM candidate)::integer % 15)) % 15) * interval '1 minute');
  IF candidate < now() THEN
    candidate := candidate + interval '15 minutes';
  END IF;

  IF p.quiet_hours_start IS NOT NULL AND p.quiet_hours_end IS NOT NULL THEN
    local_now := candidate AT TIME ZONE COALESCE(p.timezone, 'UTC');
    local_minutes := extract(hour FROM local_now)::integer * 60 + extract(minute FROM local_now)::integer;
    start_minutes := extract(hour FROM p.quiet_hours_start)::integer * 60 + extract(minute FROM p.quiet_hours_start)::integer;
    end_minutes := extract(hour FROM p.quiet_hours_end)::integer * 60 + extract(minute FROM p.quiet_hours_end)::integer;

    IF (
      (start_minutes <= end_minutes AND local_minutes >= start_minutes AND local_minutes < end_minutes)
      OR
      (start_minutes > end_minutes AND (local_minutes >= start_minutes OR local_minutes < end_minutes))
    ) THEN
      candidate := (
        (date_trunc('day', local_now)::date + p.quiet_hours_end)
        + CASE WHEN start_minutes > end_minutes AND local_minutes >= start_minutes THEN interval '1 day' ELSE interval '0' END
      ) AT TIME ZONE COALESCE(p.timezone, 'UTC');
    END IF;
  END IF;

  budget := CASE p.drop_frequency
    WHEN 'weekly' THEN app_config_int('drop_budget_weekly', 1)
    WHEN '3xwk' THEN app_config_int('drop_budget_3xwk', 3)
    ELSE app_config_int('drop_budget_daily', 7)
  END;

  SELECT count(*) INTO sent_count
  FROM notification_events
  WHERE user_id = p_user
    AND type = 'sent'::notification_event_type
    AND created_at >= now() - interval '7 days';

  IF sent_count >= budget THEN
    candidate := candidate + CASE p.drop_frequency
      WHEN 'weekly' THEN interval '7 days'
      WHEN '3xwk' THEN interval '3 days'
      ELSE interval '1 day'
    END;
  END IF;

  IF bucket_id IS NULL THEN
    SELECT min(cooldown_until) INTO min_cooldown
    FROM buckets
    WHERE user_id = p_user
      AND deleted_at IS NULL
      AND cooldown_until IS NOT NULL
      AND cooldown_until > candidate
      AND NOT EXISTS (
        SELECT 1 FROM buckets b2
        WHERE b2.user_id = p_user
          AND b2.deleted_at IS NULL
          AND (b2.cooldown_until IS NULL OR b2.cooldown_until <= candidate)
      );
  ELSE
    SELECT cooldown_until INTO min_cooldown
    FROM buckets
    WHERE id = bucket_id
      AND user_id = p_user
      AND deleted_at IS NULL
      AND cooldown_until > candidate;
  END IF;

  IF min_cooldown IS NOT NULL THEN
    candidate := min_cooldown;
  END IF;

  RETURN candidate;
END;
$$;

CREATE OR REPLACE FUNCTION current_stack_usage_rpc()
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  tz text;
  per text;
  cnt integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(timezone, 'UTC') INTO tz
  FROM profiles
  WHERE id = p_user;

  per := to_char((now() AT TIME ZONE COALESCE(tz, 'UTC')), 'YYYY-MM');

  SELECT stacks_created INTO cnt
  FROM user_usage_monthly
  WHERE user_id = p_user AND period = per;

  RETURN COALESCE(cnt, 0);
END;
$$;

-- ---------------------------------------------------------------------
-- Function privileges.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  app_config_int(text, integer),
  engine_params(uuid, uuid),
  engine_retrievability(numeric, timestamptz, timestamptz),
  engine_interval_days(numeric, numeric),
  engine_comfort(numeric, numeric),
  engine_stability_from_comfort(smallint, numeric),
  engine_s0(review_grade, smallint),
  engine_grade_value(review_grade),
  engine_success_stability(numeric, smallint, review_grade, numeric, numeric, numeric, numeric, numeric, numeric),
  engine_lapse_stability(numeric, smallint, numeric, numeric, numeric, numeric, numeric, numeric),
  engine_drift_difficulty(smallint, review_grade, numeric),
  engine_heat(numeric, timestamptz, timestamptz, smallint, smallint, numeric, timestamptz),
  engine_interval_label(numeric),
  stack_payload_json(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  record_review_rpc(jsonb),
  generate_stack_rpc(uuid[], boolean, integer),
  preview_due_interval_rpc(uuid),
  next_drop_time_rpc(uuid),
  current_stack_usage_rpc()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  record_review_rpc(jsonb),
  generate_stack_rpc(uuid[], boolean, integer),
  preview_due_interval_rpc(uuid),
  next_drop_time_rpc(uuid),
  current_stack_usage_rpc()
TO authenticated;
