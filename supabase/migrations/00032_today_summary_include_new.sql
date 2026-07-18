-- Align today_summary_rpc due_count with generate_stack_rpc / due_pool_preview_rpc.
-- New (never-reviewed) cards are stack-eligible but were excluded from the Today
-- ring, so users saw e.g. "5 due" then opened a 6-card session that included a
-- `new` note. Count `new` the same way as the stack generator.

SET search_path = public, extensions;

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

REVOKE ALL ON FUNCTION today_summary_rpc() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION today_summary_rpc() TO authenticated;
