-- S16 · Recall Drop trigger (backend-authoritative).
-- compute_due_candidates() evaluates the Drop trigger for every opted-in user in
-- a single set-based query and returns only the users who should receive a Drop
-- right now. The compute-due Edge Function (service role) consumes this and does
-- the FCM I/O + 'sent' logging — no product logic lives in the function or app.
-- Trigger spec: Roadmap/sprints/S16-notifications.md §"Drop trigger".
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-9] [D-ENG-9] [Block B5].

-- is_in_quiet_hours: true when p_now (in p_tz) falls inside [start, end), with
-- wrap-around support for windows that span midnight (e.g. 22:00–08:00).
-- Mirrors the minute-math in next_drop_time_rpc (00004).
CREATE OR REPLACE FUNCTION is_in_quiet_hours(
  p_now timestamptz,
  p_tz text,
  p_start time,
  p_end time
) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE
  local_now timestamp;
  local_minutes integer;
  start_minutes integer;
  end_minutes integer;
BEGIN
  IF p_start IS NULL OR p_end IS NULL THEN
    RETURN false;
  END IF;

  local_now := p_now AT TIME ZONE COALESCE(p_tz, 'UTC');
  local_minutes := extract(hour FROM local_now)::integer * 60 + extract(minute FROM local_now)::integer;
  start_minutes := extract(hour FROM p_start)::integer * 60 + extract(minute FROM p_start)::integer;
  end_minutes := extract(hour FROM p_end)::integer * 60 + extract(minute FROM p_end)::integer;

  RETURN (
    (start_minutes <= end_minutes AND local_minutes >= start_minutes AND local_minutes < end_minutes)
    OR
    (start_minutes > end_minutes AND (local_minutes >= start_minutes OR local_minutes < end_minutes))
  );
END;
$$;

-- compute_due_candidates: one row per user eligible for a Drop *now*. ALL of the
-- following must hold (Drop trigger, S16 §3):
--   • push_opt_in = true and has ≥1 registered device token
--   • not currently in quiet hours (profiles tz)
--   • within the rolling-7-day frequency budget [D-ENG-9]
--   • ≥1 active scope bucket out of cooldown (downgraded → first 3 [Block B5])
--   • due_pool_size ≥ drop_threshold (5) OR an overdue priority-5 card exists
--   • no 'sent' Drop already logged for today's dedupe_key [D-EF-9]
CREATE OR REPLACE FUNCTION compute_due_candidates()
RETURNS TABLE (
  user_id uuid,
  dedupe_key text,
  due_pool_size integer,
  tokens jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_now timestamptz := now();
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT
      p.id AS uid,
      COALESCE(p.timezone, 'UTC') AS tz,
      p.drop_frequency,
      p.quiet_hours_start,
      p.quiet_hours_end,
      (p.id::text || ':' || ((v_now AT TIME ZONE COALESCE(p.timezone, 'UTC'))::date)::text) AS dkey
    FROM profiles p
    WHERE p.push_opt_in = true
  )
  SELECT
    c.uid,
    c.dkey,
    pool.due_pool_size,
    tok.tokens
  FROM candidates c
  CROSS JOIN LATERAL (SELECT * FROM engine_params(c.uid, NULL)) sp
  CROSS JOIN LATERAL (
    SELECT array_agg(b.id) AS scope_ids
    FROM active_buckets_for_user(c.uid) b
    WHERE b.cooldown_until IS NULL OR b.cooldown_until <= v_now
  ) scope
  CROSS JOIN LATERAL (
    SELECT
      count(*)::integer AS due_pool_size,
      COALESCE(bool_or(
        n.priority = 5 AND n.due_at IS NOT NULL AND n.due_at <= v_now
      ), false) AS overdue_p5
    FROM nodes n
    WHERE scope.scope_ids IS NOT NULL
      AND n.bucket_id = ANY(scope.scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour')
        )
      )
  ) pool
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('platform', dt.platform, 'token', dt.token)) AS tokens
    FROM device_tokens dt
    WHERE dt.user_id = c.uid
  ) tok
  WHERE NOT is_in_quiet_hours(v_now, c.tz, c.quiet_hours_start, c.quiet_hours_end)
    AND scope.scope_ids IS NOT NULL
    AND tok.tokens IS NOT NULL
    AND (pool.due_pool_size >= sp.drop_threshold OR pool.overdue_p5)
    AND (
      SELECT count(*)
      FROM notification_events ne
      WHERE ne.user_id = c.uid
        AND ne.type = 'sent'::notification_event_type
        AND ne.created_at >= v_now - interval '7 days'
    ) < CASE c.drop_frequency
          WHEN 'weekly' THEN app_config_int('drop_budget_weekly', 1)
          WHEN '3xwk' THEN app_config_int('drop_budget_3xwk', 3)
          ELSE app_config_int('drop_budget_daily', 7)
        END
    AND NOT EXISTS (
      SELECT 1
      FROM notification_events ne2
      WHERE ne2.dedupe_key = c.dkey
        AND ne2.type = 'sent'::notification_event_type
    );
END;
$$;

-- Service-role only: the cron-driven compute-due EF is the sole caller.
REVOKE ALL ON FUNCTION
  is_in_quiet_hours(timestamptz, text, time, time),
  compute_due_candidates()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION compute_due_candidates() TO service_role;
