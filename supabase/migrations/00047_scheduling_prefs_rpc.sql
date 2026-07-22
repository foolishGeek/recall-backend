-- Memory strength (desired retention) write + read path.
--
-- FSRS already schedules against scheduling_params.target_retention, resolved
-- bucket > user > global by engine_params() (00004). But target_retention was
-- never user-writable (scheduling_params is SELECT-only under RLS) and no UI
-- exposed it. These two SECURITY DEFINER RPCs let a user set their own default
-- and per-bucket overrides safely:
--
--   set_scheduling_prefs_rpc(p_bucket_id, p_target_retention)
--       p_bucket_id NULL  -> user-level default row (user_id = me, bucket_id NULL)
--       p_bucket_id set    -> per-bucket override (verified owned)
--       p_target_retention NULL -> clear that override (revert to inherited)
--
--   get_scheduling_prefs_rpc(p_bucket_id)
--       returns { app_default, user_value, bucket_value, effective }
--       so the client can show "Uses your default" vs an explicit override.
--
-- Retention is clamped to [0.80, 0.97]: below ~0.80 intervals grow so long that
-- recall genuinely suffers; above ~0.97 review load explodes for tiny gains.
-- Fail closed: unauthenticated or non-owned bucket -> exception, no write.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION set_scheduling_prefs_rpc(
  p_bucket_id uuid DEFAULT NULL,
  p_target_retention numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  v_clamped numeric;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- Per-bucket override must target a bucket the caller owns.
  IF p_bucket_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM buckets
      WHERE id = p_bucket_id AND user_id = p_user AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- NULL retention = clear this override / revert to inherited value.
  IF p_target_retention IS NULL THEN
    IF p_bucket_id IS NULL THEN
      DELETE FROM scheduling_params
      WHERE user_id = p_user AND bucket_id IS NULL;
    ELSE
      DELETE FROM scheduling_params
      WHERE bucket_id = p_bucket_id;
    END IF;
    RETURN get_scheduling_prefs_rpc(p_bucket_id);
  END IF;

  v_clamped := LEAST(0.97, GREATEST(0.80, p_target_retention));

  IF p_bucket_id IS NULL THEN
    INSERT INTO scheduling_params (user_id, bucket_id, target_retention)
    VALUES (p_user, NULL, v_clamped)
    ON CONFLICT (user_id, bucket_id)
    DO UPDATE SET target_retention = EXCLUDED.target_retention;
  ELSE
    INSERT INTO scheduling_params (user_id, bucket_id, target_retention)
    VALUES (p_user, p_bucket_id, v_clamped)
    ON CONFLICT (user_id, bucket_id)
    DO UPDATE SET target_retention = EXCLUDED.target_retention;
  END IF;

  RETURN get_scheduling_prefs_rpc(p_bucket_id);
END;
$$;

CREATE OR REPLACE FUNCTION get_scheduling_prefs_rpc(
  p_bucket_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  v_app_default numeric;
  v_user numeric;
  v_bucket numeric;
  v_effective numeric;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF p_bucket_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM buckets
      WHERE id = p_bucket_id AND user_id = p_user AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT target_retention INTO v_app_default
  FROM scheduling_params WHERE user_id IS NULL AND bucket_id IS NULL;

  SELECT target_retention INTO v_user
  FROM scheduling_params WHERE user_id = p_user AND bucket_id IS NULL;

  IF p_bucket_id IS NOT NULL THEN
    SELECT target_retention INTO v_bucket
    FROM scheduling_params WHERE bucket_id = p_bucket_id;
  END IF;

  -- Mirror engine_params resolution: bucket > user > global.
  v_effective := COALESCE(v_bucket, v_user, v_app_default);

  RETURN jsonb_build_object(
    'app_default', v_app_default,
    'user_value', v_user,
    'bucket_value', v_bucket,
    'effective', v_effective
  );
END;
$$;

REVOKE ALL ON FUNCTION set_scheduling_prefs_rpc(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_scheduling_prefs_rpc(uuid, numeric) TO authenticated;

REVOKE ALL ON FUNCTION get_scheduling_prefs_rpc(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_scheduling_prefs_rpc(uuid) TO authenticated;
