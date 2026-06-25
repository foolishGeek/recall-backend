-- S10 fix — due_pool_preview_rpc excluded `new` cards, so a user whose only due
-- items are freshly-added (never-reviewed) nodes saw `due_count` > 0 in the Today
-- ring but an EMPTY peeking card stack. Align the preview's eligibility with
-- today_summary_rpc / generate_stack_rpc (include `new` cards) so the stack the
-- user sees always matches the ring. Idempotent (CREATE OR REPLACE).

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

REVOKE ALL ON FUNCTION due_pool_preview_rpc(integer)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION due_pool_preview_rpc(integer) TO authenticated;
