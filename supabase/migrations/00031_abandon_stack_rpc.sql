-- S11 · Abandon mid-stack.
-- Marks the stack abandoned and clears cooldown on scope buckets that still
-- have due cards, so Today shows remaining work (S11: "unreviewed stay due").
-- Cooldown is applied at generate_stack_rpc time; without this, abandoning
-- mid-session leaves the bucket cooling and Today shows 0 even with due nodes.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION abandon_stack_rpc(p_stack_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  s_row stacks%ROWTYPE;
  scope_ids uuid[];
  v_now timestamptz := now();
  cleared_ids uuid[] := ARRAY[]::uuid[];
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

  -- Idempotent: already abandoned / completed → no-op success.
  IF s_row.status <> 'active' THEN
    RETURN jsonb_build_object(
      'status', s_row.status::text,
      'already_finalized', true,
      'cleared_bucket_ids', '[]'::jsonb
    );
  END IF;

  UPDATE stacks
  SET status = 'abandoned',
      updated_at = v_now
  WHERE id = p_stack_id;

  scope_ids := COALESCE(
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(s_row.scope->'bucket_ids') x),
    ARRAY[]::uuid[]
  );

  -- Clear cooldown only where remaining due cards exist (learning/review/relearning).
  -- Buckets fully drained keep their cooldown (same as a finished pass through them).
  WITH due_buckets AS (
    SELECT DISTINCT n.bucket_id
    FROM nodes n
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
      AND n.due_at IS NOT NULL
      AND n.due_at <= v_now
  ),
  cleared AS (
    UPDATE buckets b
    SET cooldown_until = NULL,
        updated_at = v_now
    FROM due_buckets d
    WHERE b.id = d.bucket_id
      AND b.user_id = p_user
      AND b.deleted_at IS NULL
      AND b.cooldown_until IS NOT NULL
      AND b.cooldown_until > v_now
    RETURNING b.id
  )
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO cleared_ids FROM cleared;

  RETURN jsonb_build_object(
    'status', 'abandoned',
    'already_finalized', false,
    'cleared_bucket_ids', to_jsonb(cleared_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION abandon_stack_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION abandon_stack_rpc(uuid) TO authenticated;
