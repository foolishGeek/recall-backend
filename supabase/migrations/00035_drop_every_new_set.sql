-- S16 revision · Recall Drop fires on EVERY new set of cards (not once/day).
-- Supersedes the [D-EF-9] "<=1 sent per local day" dedupe and the [D-ENG-9]
-- rolling-7-day frequency budget for the trigger. New model (watermark):
--   * A user is notified again only when >= drop_threshold cards have *newly*
--     matured (due_at) since their last 'sent' Drop, so the same standing pool
--     is announced once, but fresh waves re-trigger — multiple times per day.
--   * dedupe_key is now unique per send (minute-stamped), so notification_events
--     still enforces UNIQUE (dedupe_key, type) without suppressing later Drops.
--   * Guardrails replacing the daily cap: a minimum interval between sends
--     (drop_min_interval_minutes) and a per-local-day safety cap
--     (drop_max_per_day). Quiet hours are unchanged.
-- Also tightens the cron cadence from 15 min to 5 min so "ready" is felt sooner.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-9] [D-ENG-9] (amended).

-- New tunables (idempotent seed).
INSERT INTO app_config (key, value) VALUES
  ('drop_min_interval_minutes','30'::jsonb),
  ('drop_max_per_day','6'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- Drop pool: truly due learning/review/relearning only (no new inflation).
-- Trigger now keys on cards that matured since the last 'sent' Drop.
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
      p.quiet_hours_start,
      p.quiet_hours_end,
      -- Unique per send (minute granularity); the min-interval guard below
      -- guarantees two sends for one user never share a minute.
      (p.id::text || ':' ||
        to_char(v_now AT TIME ZONE COALESCE(p.timezone, 'UTC'), 'YYYYMMDD"T"HH24MI')) AS dkey
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
    -- Watermark: newest 'sent' Drop + how many Drops already went out today.
    SELECT
      max(ne.created_at) AS last_sent_at,
      count(*) FILTER (
        WHERE (ne.created_at AT TIME ZONE c.tz)::date = (v_now AT TIME ZONE c.tz)::date
      )::integer AS sent_today
    FROM notification_events ne
    WHERE ne.user_id = c.uid
      AND ne.type = 'sent'::notification_event_type
  ) ls
  CROSS JOIN LATERAL (
    SELECT
      count(*)::integer AS due_pool_size,
      count(*) FILTER (
        WHERE n.due_at > COALESCE(ls.last_sent_at, '-infinity'::timestamptz)
      )::integer AS newly_due,
      COALESCE(bool_or(
        n.priority = 5
        AND n.due_at > COALESCE(ls.last_sent_at, '-infinity'::timestamptz)
      ), false) AS new_overdue_p5
    FROM nodes n
    WHERE scope.scope_ids IS NOT NULL
      AND n.bucket_id = ANY(scope.scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
      AND n.due_at IS NOT NULL
      AND n.due_at <= v_now
  ) pool
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('platform', dt.platform, 'token', dt.token)) AS tokens
    FROM device_tokens dt
    WHERE dt.user_id = c.uid
  ) tok
  WHERE NOT is_in_quiet_hours(v_now, c.tz, c.quiet_hours_start, c.quiet_hours_end)
    AND scope.scope_ids IS NOT NULL
    AND tok.tokens IS NOT NULL
    -- Fire only when a fresh batch matured since the last Drop.
    AND (pool.newly_due >= sp.drop_threshold OR pool.new_overdue_p5)
    -- Anti-spam: keep a minimum gap between two Drops for the same user.
    AND (
      ls.last_sent_at IS NULL
      OR ls.last_sent_at <= v_now - make_interval(mins => app_config_int('drop_min_interval_minutes', 30))
    )
    -- Safety cap on total Drops per local day.
    AND ls.sent_today < app_config_int('drop_max_per_day', 6);
END;
$$;

REVOKE ALL ON FUNCTION compute_due_candidates() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION compute_due_candidates() TO service_role;

-- Tighten the Drop cron cadence 15 min -> 5 min. Idempotent: unschedule any
-- prior job (old or new name), then schedule the 5-min job.
DO $$
BEGIN
  PERFORM cron.unschedule(jobid)
  FROM cron.job
  WHERE jobname IN ('compute-due-15min', 'compute-due-5min');

  PERFORM cron.schedule(
    'compute-due-5min',
    '*/5 * * * *',
    $cron$ SELECT public.invoke_compute_due(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping compute-due reschedule';
END;
$$;
