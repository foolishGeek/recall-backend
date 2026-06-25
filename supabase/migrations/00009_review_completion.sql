-- S11 · Review session completion RPC.
-- Atomically marks a stack completed (fires on_stack_completed trigger for XP/achievements)
-- and returns cooling bucket data for the mobile toast.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION complete_stack_rpc(p_stack_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  s_row stacks%ROWTYPE;
  scope_ids uuid[];
  cooling jsonb;
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
      completed_at = now(),
      updated_at = now()
  WHERE id = p_stack_id;

  scope_ids := COALESCE(
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(s_row.scope->'bucket_ids') x),
    ARRAY[]::uuid[]
  );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'name', b.name,
    'cooldown_days', ceil(extract(epoch FROM (b.cooldown_until - now())) / 86400.0)::integer
  )), '[]'::jsonb)
  INTO cooling
  FROM buckets b
  WHERE b.id = ANY(scope_ids)
    AND b.user_id = p_user
    AND b.deleted_at IS NULL
    AND b.cooldown_until IS NOT NULL
    AND b.cooldown_until > now();

  RETURN jsonb_build_object('already_completed', false, 'cooling_buckets', cooling);
END;
$$;

REVOKE ALL ON FUNCTION complete_stack_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_stack_rpc(uuid) TO authenticated;
