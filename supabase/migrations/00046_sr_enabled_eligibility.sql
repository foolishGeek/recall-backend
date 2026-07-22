-- Honour nodes.sr_enabled (00045) in every place that decides "is this note
-- schedulable / due right now". A note with sr_enabled = false is a plain saved
-- note: it never enters a stack, the Today ring, the due preview, the ahead
-- count, or (via 00049) a Recall Drop.
--
-- These are faithful re-creations of the latest bodies:
--   generate_stack_rpc      (00033)
--   today_summary_rpc       (00032)
--   due_pool_preview_rpc    (00030)
--   review_ahead_count_rpc  (00030)
-- with a single added predicate `AND n.sr_enabled` on the node scan.
-- compute_due_candidates is handled in 00049 (its re-nudge rewrite includes the
-- same filter) to avoid re-declaring that body twice.
--
-- CREATE OR REPLACE keeps this idempotent; grants are re-asserted at the end.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- generate_stack_rpc — 00033 body + sr_enabled filter
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

  -- Cooldown is applied on complete_stack_rpc only (not here).

  RETURN stack_payload_json(new_stack.id) || jsonb_build_object('existing', false);
END;
$$;

-- ---------------------------------------------------------------------
-- today_summary_rpc — 00032 body + sr_enabled filter
-- ---------------------------------------------------------------------
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
    AND n.sr_enabled
    AND n.state <> 'leech'::node_state
    AND (b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
    AND (
      n.state = 'new'::node_state
      OR (
        n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
        AND n.due_at IS NOT NULL
        AND n.due_at <= v_now
      )
    );

  RETURN jsonb_build_object(
    'due_count', COALESCE(v_due_count, 0),
    'aggregate_heat', 0,
    'hot_count', 0,
    'warm_count', 0,
    'cool_count', 0
  );
END;
$$;

-- ---------------------------------------------------------------------
-- due_pool_preview_rpc — 00030 body + sr_enabled filter
-- ---------------------------------------------------------------------
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
          AND n.sr_enabled
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

-- ---------------------------------------------------------------------
-- review_ahead_count_rpc — 00030 body + sr_enabled filter
-- ---------------------------------------------------------------------
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
      AND n.sr_enabled
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

-- Re-assert least-privilege grants (unchanged from source migrations).
REVOKE ALL ON FUNCTION generate_stack_rpc(uuid[], boolean, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION generate_stack_rpc(uuid[], boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION today_summary_rpc() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION today_summary_rpc() TO authenticated;

REVOKE ALL ON FUNCTION due_pool_preview_rpc(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION due_pool_preview_rpc(integer) TO authenticated;

REVOKE ALL ON FUNCTION review_ahead_count_rpc() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION review_ahead_count_rpc() TO authenticated;
