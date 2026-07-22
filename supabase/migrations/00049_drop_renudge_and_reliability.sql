-- Recall Drops: reliable + persistent nudging.
--
-- Three things happen here:
--   1. Re-nudge: if a user still has due cards they have NOT seen or reviewed,
--      re-announce after `drop_renudge_hours` (default 2h). The 00035 watermark
--      alone only fired on a *fresh* wave, so an ignored Drop went silent until
--      new cards matured. Now unseen work keeps (politely) knocking.
--   2. Reminder style: profiles.drop_frequency is repurposed from a dead cadence
--      budget into a real intensity dial via drop_intensity():
--         weekly -> Gentle · 3xwk -> Standard · daily -> Persistent
--      (existing wire values reused; no schema/CHECK change; the client relabels).
--   3. Reliability: exclude sr_enabled = false notes from the pool; add a `failed`
--      event type (logged by the edge fn) so transient FCM failures are auditable
--      and retried next tick; add prune_stale_device_tokens() for token hygiene.
--
-- next_drop_time_rpc is rewritten to match this model (was stale 15-min + 7-day
-- budget). Fail closed everywhere; STABLE read RPCs never write.

SET search_path = public, extensions;

-- 1. New config knobs (idempotent seed).
INSERT INTO app_config (key, value) VALUES
  ('drop_renudge_hours', '2'::jsonb),
  ('device_token_ttl_days', '60'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- 2. `failed` audit type for notification_events. Top-level ADD VALUE IF NOT
-- EXISTS is idempotent (PG12+) and, unlike a DO/PL-pgSQL block, is not rejected
-- as "cannot run inside a transaction block". The value is not referenced
-- elsewhere in this migration, so it is safe to add here and use at runtime.
ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'failed';

-- 3. Reminder-style intensity dial. Single source of truth for the Drop knobs,
-- reused by compute_due_candidates + next_drop_time_rpc.
CREATE OR REPLACE FUNCTION drop_intensity(p_frequency text)
RETURNS TABLE (
  threshold integer,
  min_interval_min integer,
  max_per_day integer,
  renudge_hours integer
)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT * FROM (
    VALUES
      ('weekly', 8, 240, 3, 0),                                        -- Gentle
      ('3xwk',   5,  60, 6, app_config_int('drop_renudge_hours', 2)),  -- Standard
      ('daily',  3,  30, 8, app_config_int('drop_renudge_hours', 2))   -- Persistent
  ) AS v(freq, threshold, min_interval_min, max_per_day, renudge_hours)
  WHERE v.freq = COALESCE(NULLIF(p_frequency, ''), 'daily')
  UNION ALL
  -- Fallback to Persistent for any unexpected value.
  SELECT 3, 30, 8, app_config_int('drop_renudge_hours', 2)
  WHERE COALESCE(NULLIF(p_frequency, ''), 'daily') NOT IN ('weekly', '3xwk', 'daily')
  LIMIT 1;
$$;

-- 4. Token hygiene: drop tokens not seen in device_token_ttl_days. Service-role
-- maintenance called by the cron (00050); pairs with UNREGISTERED pruning in the
-- edge function.
CREATE INDEX IF NOT EXISTS idx_device_tokens_last_seen
  ON device_tokens (last_seen_at);

CREATE OR REPLACE FUNCTION prune_stale_device_tokens()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM device_tokens
  WHERE last_seen_at < now() - make_interval(days => app_config_int('device_token_ttl_days', 60));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION prune_stale_device_tokens() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION prune_stale_device_tokens() TO service_role;

-- 5. Drop trigger: watermark (fresh wave) OR re-nudge (unseen due work), scoped
-- to sr_enabled notes, gated by intensity + quiet hours.
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
  CROSS JOIN LATERAL (SELECT * FROM drop_intensity(c.drop_frequency)) di
  CROSS JOIN LATERAL (
    SELECT array_agg(b.id) AS scope_ids
    FROM active_buckets_for_user(c.uid) b
    WHERE b.cooldown_until IS NULL OR b.cooldown_until <= v_now
  ) scope
  CROSS JOIN LATERAL (
    -- Newest 'sent' Drop + how many Drops already went out today.
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
      AND n.sr_enabled
      AND n.state <> 'leech'::node_state
      AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
      AND n.due_at IS NOT NULL
      AND n.due_at <= v_now
  ) pool
  CROSS JOIN LATERAL (
    -- Has the user engaged since the last Drop? (opened it, or reviewed anything)
    SELECT
      EXISTS (
        SELECT 1 FROM notification_events ne2
        WHERE ne2.user_id = c.uid
          AND ne2.type = 'opened'::notification_event_type
          AND ne2.created_at > COALESCE(ls.last_sent_at, '-infinity'::timestamptz)
      )
      OR EXISTS (
        SELECT 1 FROM reviews r
        WHERE r.user_id = c.uid
          AND r.reviewed_at > COALESCE(ls.last_sent_at, '-infinity'::timestamptz)
      ) AS seen_since_last
  ) eng
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('platform', dt.platform, 'token', dt.token)) AS tokens
    FROM device_tokens dt
    WHERE dt.user_id = c.uid
  ) tok
  WHERE NOT is_in_quiet_hours(v_now, c.tz, c.quiet_hours_start, c.quiet_hours_end)
    AND scope.scope_ids IS NOT NULL
    AND tok.tokens IS NOT NULL
    AND (
      -- Fresh wave matured since the last Drop...
      pool.newly_due >= di.threshold
      OR pool.new_overdue_p5
      -- ...or a re-nudge: still-due work the user has not seen or reviewed.
      OR (
        di.renudge_hours > 0
        AND pool.due_pool_size > 0
        AND ls.last_sent_at IS NOT NULL
        AND ls.last_sent_at <= v_now - make_interval(hours => di.renudge_hours)
        AND NOT eng.seen_since_last
      )
    )
    -- Anti-spam: minimum gap between two Drops.
    AND (
      ls.last_sent_at IS NULL
      OR ls.last_sent_at <= v_now - make_interval(mins => di.min_interval_min)
    )
    -- Safety cap per local day.
    AND ls.sent_today < di.max_per_day;
END;
$$;

REVOKE ALL ON FUNCTION compute_due_candidates() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION compute_due_candidates() TO service_role;

-- 6. next_drop_time_rpc — honest ETA under the watermark + re-nudge model.
-- Returns the earliest time a Drop could realistically fire: not before the
-- min-interval since the last send, aligned to the 5-min cron, using the next
-- card maturity when nothing is due yet, pushed out of quiet hours and past any
-- blocking bucket cooldown. NULL when the user has no buckets.
CREATE OR REPLACE FUNCTION next_drop_time_rpc(bucket_id uuid DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  p profiles%ROWTYPE;
  di record;
  scope_ids uuid[];
  last_sent_at timestamptz;
  due_now_count integer;
  next_due timestamptz;
  candidate timestamptz;
  local_now timestamp;
  local_minutes integer;
  start_minutes integer;
  end_minutes integer;
  min_cooldown timestamptz;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO p FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF bucket_id IS NOT NULL AND NOT owns_bucket(bucket_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- Scope: a single bucket, or all non-deleted buckets currently out of cooldown.
  IF bucket_id IS NULL THEN
    SELECT array_agg(id) INTO scope_ids
    FROM buckets
    WHERE user_id = p_user AND deleted_at IS NULL;

    IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
      RETURN NULL;
    END IF;

    SELECT array_agg(id) INTO scope_ids
    FROM buckets
    WHERE user_id = p_user AND deleted_at IS NULL
      AND (cooldown_until IS NULL OR cooldown_until <= now());
  ELSE
    scope_ids := ARRAY[bucket_id];
  END IF;

  SELECT * INTO di FROM drop_intensity(p.drop_frequency);

  SELECT max(created_at) INTO last_sent_at
  FROM notification_events
  WHERE user_id = p_user AND type = 'sent'::notification_event_type;

  -- Anything due right now among revision-enabled cards in scope?
  SELECT count(*)::integer INTO due_now_count
  FROM nodes n
  WHERE scope_ids IS NOT NULL
    AND n.bucket_id = ANY(scope_ids)
    AND n.deleted_at IS NULL
    AND n.sr_enabled
    AND n.state <> 'leech'::node_state
    AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
    AND n.due_at IS NOT NULL
    AND n.due_at <= now();

  IF due_now_count > 0 THEN
    -- Work is ready; the next cron tick is the earliest opportunity.
    candidate := now();
  ELSE
    -- Otherwise the next card to mature drives the ETA.
    SELECT min(n.due_at) INTO next_due
    FROM nodes n
    WHERE scope_ids IS NOT NULL
      AND n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.sr_enabled
      AND n.state <> 'leech'::node_state
      AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
      AND n.due_at IS NOT NULL
      AND n.due_at > now();

    IF next_due IS NULL THEN
      RETURN NULL; -- nothing scheduled to announce
    END IF;
    candidate := next_due;
  END IF;

  -- Never before the min-interval since the last Drop.
  IF last_sent_at IS NOT NULL THEN
    candidate := GREATEST(candidate, last_sent_at + make_interval(mins => di.min_interval_min));
  END IF;

  -- Align up to the next 5-minute cron tick.
  candidate := date_trunc('minute', candidate)
    + (((5 - (extract(minute FROM candidate)::integer % 5)) % 5) * interval '1 minute');
  IF candidate < now() THEN
    candidate := date_trunc('minute', now())
      + (((5 - (extract(minute FROM now())::integer % 5)) % 5) * interval '1 minute')
      + interval '5 minutes';
  END IF;

  -- Push out of quiet hours to the window end.
  IF p.quiet_hours_start IS NOT NULL AND p.quiet_hours_end IS NOT NULL THEN
    local_now := candidate AT TIME ZONE COALESCE(p.timezone, 'UTC');
    local_minutes := extract(hour FROM local_now)::integer * 60 + extract(minute FROM local_now)::integer;
    start_minutes := extract(hour FROM p.quiet_hours_start)::integer * 60 + extract(minute FROM p.quiet_hours_start)::integer;
    end_minutes := extract(hour FROM p.quiet_hours_end)::integer * 60 + extract(minute FROM p.quiet_hours_end)::integer;

    IF (
      (start_minutes <= end_minutes AND local_minutes >= start_minutes AND local_minutes < end_minutes)
      OR
      (start_minutes > end_minutes AND (local_minutes >= start_minutes OR local_minutes < end_minutes))
    ) THEN
      candidate := (
        (date_trunc('day', local_now)::date + p.quiet_hours_end)
        + CASE WHEN start_minutes > end_minutes AND local_minutes >= start_minutes THEN interval '1 day' ELSE interval '0' END
      ) AT TIME ZONE COALESCE(p.timezone, 'UTC');
    END IF;
  END IF;

  -- If every bucket is cooling, the soonest Drop is when the first one wakes.
  IF bucket_id IS NULL THEN
    SELECT min(cooldown_until) INTO min_cooldown
    FROM buckets
    WHERE user_id = p_user
      AND deleted_at IS NULL
      AND cooldown_until IS NOT NULL
      AND cooldown_until > candidate
      AND NOT EXISTS (
        SELECT 1 FROM buckets b2
        WHERE b2.user_id = p_user
          AND b2.deleted_at IS NULL
          AND (b2.cooldown_until IS NULL OR b2.cooldown_until <= candidate)
      );
  ELSE
    SELECT cooldown_until INTO min_cooldown
    FROM buckets
    WHERE id = bucket_id
      AND user_id = p_user
      AND deleted_at IS NULL
      AND cooldown_until > candidate;
  END IF;

  IF min_cooldown IS NOT NULL THEN
    candidate := min_cooldown;
  END IF;

  RETURN candidate;
END;
$$;

REVOKE ALL ON FUNCTION next_drop_time_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION next_drop_time_rpc(uuid) TO authenticated;
