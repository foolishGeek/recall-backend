-- Fix: cooldown at generate made Today go empty after abandon / app refresh.
-- Evidence (Stage, user avijitarm1): stack abandoned with 4 due + 1 new remaining,
-- but Maths.cooldown_until still set → today_summary_rpc returned 0.
--
-- Correct lifecycle (matches S11 complete toast + "unreviewed stay due"):
--   generate  → does NOT cool buckets
--   complete  → cools scope buckets, returns cooling toast payload
--   abandon   → clears cooldown wherever due/new work remains (repair-safe)

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- generate_stack_rpc — same as 00030, without cooldown write
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

  -- Cooldown is applied on complete_stack_rpc only (not here).

  RETURN stack_payload_json(new_stack.id) || jsonb_build_object('existing', false);
END;
$$;

-- ---------------------------------------------------------------------
-- complete_stack_rpc — apply cooldown, then return toast payload
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION complete_stack_rpc(p_stack_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  s_row stacks%ROWTYPE;
  scope_ids uuid[];
  cooling jsonb;
  v_now timestamptz := now();
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO s_row
  FROM stacks
  WHERE id = p_stack_id
    AND user_id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF s_row.status = 'completed' THEN
    RETURN jsonb_build_object('already_completed', true, 'cooling_buckets', '[]'::jsonb);
  END IF;

  IF s_row.status <> 'active' THEN
    RAISE EXCEPTION 'invalid_input: stack is not active' USING ERRCODE = '22023';
  END IF;

  UPDATE stacks
  SET status = 'completed',
      completed_at = v_now,
      updated_at = v_now
  WHERE id = p_stack_id;

  scope_ids := COALESCE(
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(s_row.scope->'bucket_ids') x),
    ARRAY[]::uuid[]
  );

  -- Cool every in-scope bucket that contributed to this completed session.
  UPDATE buckets b
  SET cooldown_until = v_now + b.cooling_period,
      updated_at = v_now
  WHERE b.id = ANY(scope_ids)
    AND b.user_id = p_user
    AND b.deleted_at IS NULL;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'name', b.name,
    'cooldown_days', ceil(extract(epoch FROM (b.cooldown_until - v_now)) / 86400.0)::integer
  )), '[]'::jsonb)
  INTO cooling
  FROM buckets b
  WHERE b.id = ANY(scope_ids)
    AND b.user_id = p_user
    AND b.deleted_at IS NULL
    AND b.cooldown_until IS NOT NULL
    AND b.cooldown_until > v_now;

  RETURN jsonb_build_object('already_completed', false, 'cooling_buckets', cooling);
END;
$$;

-- ---------------------------------------------------------------------
-- abandon_stack_rpc — repair-safe cooldown clear (includes new cards)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abandon_stack_rpc(p_stack_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  s_row stacks%ROWTYPE;
  scope_ids uuid[];
  v_now timestamptz := now();
  cleared_ids uuid[] := ARRAY[]::uuid[];
  was_active boolean;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO s_row
  FROM stacks
  WHERE id = p_stack_id
    AND user_id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  was_active := (s_row.status = 'active');

  IF was_active THEN
    UPDATE stacks
    SET status = 'abandoned',
        updated_at = v_now
    WHERE id = p_stack_id;
  END IF;

  -- Never leave due/new work hidden behind a stuck generate-time cooldown,
  -- even if the stack was already abandoned by an older client.
  IF s_row.status IN ('active'::stack_status, 'abandoned'::stack_status) THEN
    scope_ids := COALESCE(
      (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(s_row.scope->'bucket_ids') x),
      ARRAY[]::uuid[]
    );

    WITH remaining AS (
      SELECT DISTINCT n.bucket_id
      FROM nodes n
      WHERE n.bucket_id = ANY(scope_ids)
        AND n.deleted_at IS NULL
        AND n.state <> 'leech'::node_state
        AND (
          n.state = 'new'::node_state
          OR (
            n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
            AND n.due_at IS NOT NULL
            AND n.due_at <= v_now
          )
        )
    ),
    cleared AS (
      UPDATE buckets b
      SET cooldown_until = NULL,
          updated_at = v_now
      FROM remaining r
      WHERE b.id = r.bucket_id
        AND b.user_id = p_user
        AND b.deleted_at IS NULL
        AND b.cooldown_until IS NOT NULL
        AND b.cooldown_until > v_now
      RETURNING b.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO cleared_ids FROM cleared;
  END IF;

  RETURN jsonb_build_object(
    'status', CASE WHEN was_active THEN 'abandoned' ELSE s_row.status::text END,
    'already_finalized', NOT was_active,
    'cleared_bucket_ids', to_jsonb(cleared_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION generate_stack_rpc(uuid[], boolean, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION generate_stack_rpc(uuid[], boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION complete_stack_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_stack_rpc(uuid) TO authenticated;

REVOKE ALL ON FUNCTION abandon_stack_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION abandon_stack_rpc(uuid) TO authenticated;
