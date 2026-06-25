-- S10 · Today screen RPCs. Read-only summaries of the due pool for the Today
-- tab. Uses the exact same eligibility predicates as generate_stack_rpc (00004)
-- so the numbers the user sees always match what a generated stack would contain.

-- today_summary_rpc: aggregate due-pool stats (due count, heat distribution).
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

  SELECT array_agg(b.id ORDER BY b.created_at)
    INTO scope_ids
  FROM buckets b
  WHERE b.user_id = p_user AND b.deleted_at IS NULL;

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

-- due_pool_preview_rpc: top N due nodes by heat for the peeking card stack.
-- Excludes new cards — only shows overdue/due review & relearning nodes.
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

  SELECT array_agg(b.id ORDER BY b.created_at)
    INTO scope_ids
  FROM buckets b
  WHERE b.user_id = p_user AND b.deleted_at IS NULL;

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
          AND n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour')
        ORDER BY heat DESC
        LIMIT p_limit
      ) sub
    ),
    '[]'::jsonb
  );
END;
$$;

-- Privilege block (matches pattern from 00004 lines 838–869).
REVOKE ALL ON FUNCTION today_summary_rpc()
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION due_pool_preview_rpc(integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION today_summary_rpc() TO authenticated;
GRANT EXECUTE ON FUNCTION due_pool_preview_rpc(integer) TO authenticated;
