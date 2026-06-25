-- S14 — per-node heat percentage RPC.
-- Thin SECURITY DEFINER wrapper over engine_heat() (00004) so authenticated
-- users can read a single node's heat score for the node-detail screen.

CREATE OR REPLACE FUNCTION node_heat_pct(p_node_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_heat numeric;
  v_target numeric;
BEGIN
  SELECT sp.target_retention INTO v_target
  FROM scheduling_params sp LIMIT 1;

  SELECT round(100.0 * engine_heat(
    n.stability, n.last_reviewed_at, n.due_at,
    n.priority, n.difficulty, COALESCE(v_target, 0.9), now()
  ), 1)
  INTO v_heat
  FROM nodes n
  WHERE n.id = p_node_id
    AND n.deleted_at IS NULL
    AND owns_bucket(n.bucket_id);

  RETURN COALESCE(v_heat, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION node_heat_pct(uuid) TO authenticated;
