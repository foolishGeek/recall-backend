-- S26 — Downgraded-tier server guards [Block B5].
-- Fixes bucket/node write limits for had_premium users, blocks config edits on
-- read-only buckets, and scopes stack/today RPCs to active_buckets_for_user.

-- ---------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bucket_rank_for_user(p_bucket_id uuid)
RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id uuid;
  v_created_at timestamptz;
  v_id uuid;
  v_rank bigint;
BEGIN
  SELECT user_id, created_at, id
    INTO v_user_id, v_created_at, v_id
  FROM buckets
  WHERE id = p_bucket_id AND deleted_at IS NULL;

  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT count(*) INTO v_rank
  FROM buckets
  WHERE user_id = v_user_id
    AND deleted_at IS NULL
    AND (created_at, id) <= (v_created_at, v_id);

  RETURN v_rank;
END;
$$;

CREATE OR REPLACE FUNCTION writable_bucket_count_limit(p_user uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t subscription_tier;
  had_prem boolean;
BEGIN
  SELECT COALESCE(s.tier, 'free'::subscription_tier), COALESCE(p.had_premium, false)
    INTO t, had_prem
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = p_user;

  IF t = 'premium'::subscription_tier THEN
    RETURN 999;
  END IF;
  IF had_prem THEN
    RETURN 3;
  END IF;
  RETURN 2;
END;
$$;

-- Default stack/today scope: active buckets only; explicit scope must ⊆ active set.
CREATE OR REPLACE FUNCTION resolve_stack_scope_bucket_ids(
  p_user uuid,
  scope_bucket_ids uuid[] DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  scope_ids uuid[];
  provided_count integer;
  active_ids uuid[];
BEGIN
  IF scope_bucket_ids IS NULL THEN
    SELECT array_agg(b.id ORDER BY b.created_at)
      INTO scope_ids
    FROM active_buckets_for_user(p_user) b;
    RETURN scope_ids;
  END IF;

  SELECT count(*) INTO provided_count FROM unnest(scope_bucket_ids);

  SELECT array_agg(ab.id)
    INTO active_ids
  FROM active_buckets_for_user(p_user) ab;

  SELECT array_agg(b.id ORDER BY b.created_at)
    INTO scope_ids
  FROM buckets b
  WHERE b.user_id = p_user
    AND b.deleted_at IS NULL
    AND b.id = ANY(scope_bucket_ids)
    AND b.id = ANY(COALESCE(active_ids, ARRAY[]::uuid[]));

  IF COALESCE(array_length(scope_ids, 1), 0) <> provided_count THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  RETURN scope_ids;
END;
$$;

-- ---------------------------------------------------------------------
-- Bucket INSERT limit (free 2, downgraded 3, premium unlimited)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_bucket_limit() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_limit integer;
  cnt integer;
BEGIN
  v_limit := writable_bucket_count_limit(NEW.user_id);
  IF v_limit >= 999 THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO cnt
  FROM buckets
  WHERE user_id = NEW.user_id AND deleted_at IS NULL;

  IF cnt >= v_limit THEN
    RAISE EXCEPTION 'free_tier_bucket_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- Node write guard — all INSERT/UPDATE; rank ≤ limit for free/downgraded
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_node_bucket_writable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id uuid;
  v_limit integer;
  v_rank bigint;
BEGIN
  SELECT b.user_id INTO v_user_id
  FROM buckets b
  WHERE b.id = NEW.bucket_id AND b.deleted_at IS NULL;

  IF v_user_id IS NULL OR v_user_id != auth.uid() THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0001';
  END IF;

  v_limit := writable_bucket_count_limit(v_user_id);
  IF v_limit >= 999 THEN
    RETURN NEW;
  END IF;

  SELECT bucket_rank_for_user(NEW.bucket_id) INTO v_rank;
  IF v_rank IS NULL OR v_rank > v_limit THEN
    RAISE EXCEPTION 'free_tier_bucket_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_node_bucket_writable ON nodes;
CREATE TRIGGER trigger_check_node_bucket_writable
BEFORE INSERT OR UPDATE ON nodes
FOR EACH ROW EXECUTE FUNCTION check_node_bucket_writable();

-- ---------------------------------------------------------------------
-- Bucket UPDATE guard — deny config edits on read-only buckets; allow soft-delete
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_bucket_writable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_limit integer;
  v_rank bigint;
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.user_id != auth.uid() THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0001';
  END IF;

  v_limit := writable_bucket_count_limit(NEW.user_id);
  IF v_limit >= 999 THEN
    RETURN NEW;
  END IF;

  SELECT bucket_rank_for_user(NEW.id) INTO v_rank;
  IF v_rank IS NULL OR v_rank > v_limit THEN
    RAISE EXCEPTION 'free_tier_bucket_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_bucket_writable ON buckets;
CREATE TRIGGER trigger_check_bucket_writable
BEFORE UPDATE ON buckets
FOR EACH ROW EXECUTE FUNCTION check_bucket_writable();

-- ---------------------------------------------------------------------
-- Stack / Today RPCs — scope to active_buckets_for_user
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

CREATE OR REPLACE FUNCTION today_summary_rpc()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  sp scheduling_params%ROWTYPE;
  tz text;
  scope_ids uuid[];
  v_now timestamptz := now();
  v_due_count integer;
  v_agg_heat numeric;
  v_hot integer;
  v_warm integer;
  v_cool integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RETURN jsonb_build_object(
      'due_count', 0,
      'aggregate_heat', 0,
      'hot_count', 0,
      'warm_count', 0,
      'cool_count', 0
    );
  END IF;

  SELECT COALESCE(p.timezone, 'UTC') INTO tz
  FROM profiles p WHERE p.id = p_user;

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

  WITH eligible AS (
    SELECT
      engine_heat(
        n.stability, n.last_reviewed_at, n.due_at,
        n.priority, n.difficulty, sp.target_retention, v_now
      ) AS heat_value
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND (b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour')
        )
      )
  )
  SELECT
    count(*),
    COALESCE(avg(heat_value), 0),
    count(*) FILTER (WHERE heat_value >= 0.7),
    count(*) FILTER (WHERE heat_value >= 0.3 AND heat_value < 0.7),
    count(*) FILTER (WHERE heat_value < 0.3)
  INTO v_due_count, v_agg_heat, v_hot, v_warm, v_cool
  FROM eligible;

  RETURN jsonb_build_object(
    'due_count', COALESCE(v_due_count, 0),
    'aggregate_heat', round(COALESCE(v_agg_heat, 0)::numeric, 4),
    'hot_count', COALESCE(v_hot, 0),
    'warm_count', COALESCE(v_warm, 0),
    'cool_count', COALESCE(v_cool, 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION due_pool_preview_rpc(p_limit integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  sp scheduling_params%ROWTYPE;
  scope_ids uuid[];
  v_now timestamptz := now();
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  scope_ids := resolve_stack_scope_bucket_ids(p_user, NULL);

  IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_json ORDER BY heat DESC)
      FROM (
        SELECT jsonb_build_object(
          'node_id', n.id,
          'title', n.title,
          'bucket_id', n.bucket_id,
          'bucket_name', b.name,
          'priority', n.priority,
          'difficulty', n.difficulty,
          'due_at', n.due_at,
          'heat', round(
            engine_heat(
              n.stability, n.last_reviewed_at, n.due_at,
              n.priority, n.difficulty, sp.target_retention, v_now
            )::numeric, 4
          )
        ) AS row_json,
        engine_heat(
          n.stability, n.last_reviewed_at, n.due_at,
          n.priority, n.difficulty, sp.target_retention, v_now
        ) AS heat
        FROM nodes n
        JOIN buckets b ON b.id = n.bucket_id
        WHERE n.bucket_id = ANY(scope_ids)
          AND n.deleted_at IS NULL
          AND n.state <> 'leech'::node_state
          AND (b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
          AND (
            n.state = 'new'::node_state
            OR (
              n.state IN ('review'::node_state, 'relearning'::node_state)
              AND n.due_at IS NOT NULL
              AND n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour')
            )
          )
        ORDER BY heat DESC
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
  v_ahead boolean := true;
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
        abs(hashtext('0:' || n.id::text)::bigint)::numeric
        / 2147483647.0
      ) AS jitter
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND (v_ahead OR b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND (v_ahead OR n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour'))
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
  SELECT count(*)::integer INTO v_count
  FROM final_ranked
  WHERE position < effective_n;

  RETURN COALESCE(v_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION
  bucket_rank_for_user(uuid),
  writable_bucket_count_limit(uuid),
  resolve_stack_scope_bucket_ids(uuid, uuid[]),
  check_bucket_writable()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  bucket_rank_for_user(uuid),
  writable_bucket_count_limit(uuid),
  resolve_stack_scope_bucket_ids(uuid, uuid[])
TO authenticated;
