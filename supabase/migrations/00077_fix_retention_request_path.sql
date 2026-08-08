-- 00077 · Fix retention request-path timeouts
-- Serve cached curve even when stale (simulated_at cleared after reviews).
-- Never run retention_simulate_rpc inside insights_dashboard_rpc.

-- ---------------------------------------------------------------------
-- retention_resolve_rpc — cache-first; simulate only when forced or empty
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retention_resolve_rpc(p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  gate jsonb;
  cached jsonb;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  gate := ai_gate_check(p_user, 'retention_simulate');
  IF COALESCE((gate->>'allowed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%', COALESCE(gate->>'error', 'premium_required')
      USING ERRCODE = 'P0001';
  END IF;

  SELECT retention_curve INTO cached
  FROM profiles
  WHERE id = p_user;

  -- Serve any saved curve unless caller explicitly forces recompute.
  -- simulated_at may be NULL after reviews; that means "stale", not "missing".
  IF cached IS NOT NULL AND NOT COALESCE(p_force, false) THEN
    RETURN cached;
  END IF;

  -- No cache and not forced: return NULL so the request path stays fast.
  -- Client paints scalars / empty and refreshes via Edge Function in background.
  IF NOT COALESCE(p_force, false) THEN
    RETURN NULL;
  END IF;

  SET LOCAL statement_timeout = '120s';
  RETURN retention_simulate_rpc(p_user);
END;
$$;

REVOKE ALL ON FUNCTION retention_resolve_rpc(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION retention_resolve_rpc(boolean) TO authenticated;

-- ---------------------------------------------------------------------
-- insights_dashboard_rpc — never simulate inline (timeout-safe)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION insights_dashboard_rpc(p_force_retention boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  gate jsonb;
  sim_allowed boolean := false;
  out jsonb := '{}'::jsonb;
  errors jsonb := '{}'::jsonb;
  v_summary jsonb;
  v_activity jsonb;
  v_lifetime jsonb;
  v_teaser jsonb;
  v_retention jsonb;
  v_stale boolean := false;
  v_mastery jsonb;
  v_bucket_count int;
  v_weak jsonb;
  v_velocity jsonb;
  v_notif_stats jsonb;
  v_notif_daily jsonb;
  v_simulated_at timestamptz;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- p_force_retention is ignored for inline simulate (never block dashboard).
  -- Client refreshes retention via EF / retention_resolve_rpc(force) in background.
  PERFORM p_force_retention;

  SELECT to_jsonb(s) INTO v_summary
  FROM v_insights_summary s
  WHERE s.user_id = p_user;
  out := out || jsonb_build_object('summary', v_summary);

  gate := ai_gate_check(p_user, 'retention_simulate');
  sim_allowed := COALESCE((gate->>'allowed')::boolean, false);
  out := out || jsonb_build_object('simulation_allowed', sim_allowed);

  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.activity_date), '[]'::jsonb)
      INTO v_activity
    FROM v_daily_activity a
    WHERE a.user_id = p_user;
    out := out || jsonb_build_object('daily_activity', COALESCE(v_activity, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('heatmap', true);
    out := out || jsonb_build_object('daily_activity', '[]'::jsonb);
  END;

  IF NOT sim_allowed THEN
    BEGIN
      SELECT to_jsonb(l) INTO v_lifetime
      FROM v_profile_lifetime l
      WHERE l.user_id = p_user;
      out := out || jsonb_build_object('lifetime', v_lifetime);
    EXCEPTION WHEN OTHERS THEN
      errors := errors || jsonb_build_object('teaser', true);
    END;

    BEGIN
      SELECT jsonb_build_object(
               'retention_with_recall', p.retention_with_recall,
               'retention_baseline', p.retention_baseline
             )
        INTO v_teaser
      FROM profiles p
      WHERE p.id = p_user;
      out := out || jsonb_build_object('teaser', v_teaser);
    EXCEPTION WHEN OTHERS THEN
      errors := errors || jsonb_build_object('preview', true);
    END;

    out := out || jsonb_build_object('errors', errors);
    RETURN out;
  END IF;

  -- Premium: attach cached retention only (never call retention_simulate_rpc).
  BEGIN
    SELECT p.retention_curve, p.retention_simulated_at
      INTO v_retention, v_simulated_at
    FROM profiles p
    WHERE p.id = p_user;

    v_stale := (v_simulated_at IS NULL)
               OR (v_simulated_at < now() - interval '15 minutes');

    IF v_retention IS NULL AND EXISTS (
         SELECT 1 FROM profiles p
         WHERE p.id = p_user AND p.retention_with_recall IS NOT NULL
       ) THEN
      SELECT jsonb_build_object(
               'retention_with_recall', p.retention_with_recall,
               'retention_baseline', p.retention_baseline,
               'curve_points', '[]'::jsonb,
               'is_projected', true,
               'review_days_count', COALESCE(
                 (v_summary->>'days_with_reviews')::int, 0),
               'memories_saved', p.memories_saved
             )
        INTO v_retention
      FROM profiles p
      WHERE p.id = p_user;
      v_stale := true;
    END IF;

    IF v_retention IS NOT NULL THEN
      out := out || jsonb_build_object(
        'retention', v_retention,
        'retention_stale', v_stale
      );
    ELSE
      out := out || jsonb_build_object(
        'retention_pending', true,
        'retention_stale', true
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('retention', true);
  END;

  BEGIN
    SELECT count(*)::int INTO v_bucket_count
    FROM buckets b
    WHERE b.user_id = p_user AND b.deleted_at IS NULL;

    SELECT COALESCE(jsonb_agg(row_json ORDER BY node_count DESC), '[]'::jsonb)
      INTO v_mastery
    FROM (
      SELECT jsonb_build_object(
               'label', b.name,
               'progress', LEAST(1.0, GREATEST(0.0, COALESCE(m.mastery_pct, 0))),
               'heat', CASE
                         WHEN COALESCE(h.node_count, 0) = 0 THEN 0.3
                         ELSE LEAST(1.0, GREATEST(0.0,
                           h.due_count::numeric / NULLIF(h.node_count, 0)))
                       END
             ) AS row_json,
             COALESCE(h.node_count, 0) AS node_count
      FROM buckets b
      LEFT JOIN v_bucket_mastery m ON m.bucket_id = b.id AND m.user_id = p_user
      LEFT JOIN v_bucket_heat h ON h.bucket_id = b.id AND h.user_id = p_user
      WHERE b.user_id = p_user AND b.deleted_at IS NULL
      ORDER BY COALESCE(h.node_count, 0) DESC
      LIMIT 4
    ) rings;

    out := out || jsonb_build_object(
      'bucket_count', COALESCE(v_bucket_count, 0),
      'mastery_rings', COALESCE(v_mastery, '[]'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('mastery', true);
  END;

  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(w)), '[]'::jsonb)
      INTO v_weak
    FROM (
      SELECT w.node_id, w.title, w.bucket_id, w.bucket_name,
             w.comfort, w.priority, w.difficulty
      FROM v_weak_topics w
      JOIN buckets b ON b.id = w.bucket_id
      WHERE b.user_id = p_user AND b.deleted_at IS NULL
      ORDER BY w.comfort ASC, w.difficulty DESC
      LIMIT 3
    ) w;
    out := out || jsonb_build_object('weak_topics', COALESCE(v_weak, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('weak', true);
  END;

  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.activity_date), '[]'::jsonb)
      INTO v_velocity
    FROM v_review_velocity_daily v
    WHERE v.user_id = p_user;
    out := out || jsonb_build_object('velocity', COALESCE(v_velocity, '[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('velocity', true);
  END;

  BEGIN
    SELECT to_jsonb(s) INTO v_notif_stats
    FROM v_notification_stats s
    WHERE s.user_id = p_user;

    SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.day), '[]'::jsonb)
      INTO v_notif_daily
    FROM (
      SELECT nd.day, nd.sent, nd.opened
      FROM v_notification_daily nd
      WHERE nd.user_id = p_user
      ORDER BY nd.day DESC
      LIMIT 7
    ) d;

    out := out || jsonb_build_object(
      'notification_stats', v_notif_stats,
      'notification_daily', COALESCE(v_notif_daily, '[]'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    errors := errors || jsonb_build_object('drops', true);
  END;

  out := out || jsonb_build_object('errors', errors);
  RETURN out;
END;
$$;

REVOKE ALL ON FUNCTION insights_dashboard_rpc(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION insights_dashboard_rpc(boolean) TO authenticated;
