-- Honest "next Drop" ETA.
--
-- Bug: the Today tab showed "next drop at 10:45 PM" but nothing ever dropped.
-- Root cause: next_drop_time_rpc (00050) computed a maturity/re-nudge ETA and
-- aligned it to the 5-min cron + quiet hours, but it never checked the two gates
-- that compute_due_candidates enforces before a Drop can actually be delivered:
--   • profiles.push_opt_in = true
--   • the user has at least one registered device_token
-- So users with notifications off (or no registered device) saw a countdown to a
-- Drop that could never fire — "hang on forever".
--
-- It also scoped on raw `buckets` while compute_due_candidates scopes on
-- active_buckets_for_user() (tier-aware: downgraded free users only get their
-- first 3 buckets). That let the ETA count work in buckets the sender ignores.
--
-- This migration rewrites next_drop_time_rpc to fail closed and use the same
-- active-bucket pool as the sender. Contract unchanged (STABLE, same signature),
-- so it returns NULL whenever a Drop is genuinely impossible; the client renders
-- that as a calm, honest state instead of a fake time.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION next_drop_time_rpc(bucket_id uuid DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  p profiles%ROWTYPE;
  di record;
  scope_ids uuid[];
  last_sent_at timestamptz;
  due_now_count integer := 0;
  newly_due integer := 0;
  new_overdue_p5 boolean := false;
  seen_since_last boolean := false;
  sent_today integer := 0;
  next_due timestamptz;
  need_more integer;
  candidate timestamptz;
  local_now timestamp;
  local_minutes integer;
  start_minutes integer;
  end_minutes integer;
  min_cooldown timestamptz;
  all_cooling boolean := false;
  tz text;
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

  -- ── Delivery gates (must mirror compute_due_candidates) ──────────────────
  -- No opt-in → a Drop can never be sent. Be honest: no ETA.
  IF NOT COALESCE(p.push_opt_in, false) THEN
    RETURN NULL;
  END IF;

  -- No registered device → nothing to deliver to. compute_due_candidates
  -- requires tok.tokens IS NOT NULL for exactly this reason.
  IF NOT EXISTS (SELECT 1 FROM device_tokens dt WHERE dt.user_id = p_user) THEN
    RETURN NULL;
  END IF;

  tz := COALESCE(p.timezone, 'UTC');

  -- ── Scope: same active-bucket pool as the sender ─────────────────────────
  IF bucket_id IS NULL THEN
    -- Any active buckets at all?
    SELECT array_agg(b.id) INTO scope_ids
    FROM active_buckets_for_user(p_user) b;

    IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
      RETURN NULL;
    END IF;

    -- Non-cooling active buckets are the ones that can drop right now.
    SELECT array_agg(b.id) INTO scope_ids
    FROM active_buckets_for_user(p_user) b
    WHERE b.cooldown_until IS NULL OR b.cooldown_until <= now();

    all_cooling := (scope_ids IS NULL OR COALESCE(array_length(scope_ids, 1), 0) = 0);
  ELSE
    -- A per-bucket ETA only makes sense for a bucket the sender actually scans.
    -- If it is not in the active pool (e.g. a downgraded free user's 4th
    -- bucket), a Drop from it is impossible → no ETA.
    IF NOT EXISTS (
      SELECT 1 FROM active_buckets_for_user(p_user) b WHERE b.id = bucket_id
    ) THEN
      RETURN NULL;
    END IF;

    scope_ids := ARRAY[bucket_id];
    SELECT COALESCE(cooldown_until > now(), false) INTO all_cooling
    FROM buckets
    WHERE id = bucket_id AND user_id = p_user AND deleted_at IS NULL;
  END IF;

  SELECT * INTO di FROM drop_intensity(p.drop_frequency);

  SELECT max(created_at) INTO last_sent_at
  FROM notification_events
  WHERE user_id = p_user AND type = 'sent'::notification_event_type;

  SELECT count(*)::integer INTO sent_today
  FROM notification_events ne
  WHERE ne.user_id = p_user
    AND ne.type = 'sent'::notification_event_type
    AND (ne.created_at AT TIME ZONE tz)::date = (now() AT TIME ZONE tz)::date;

  IF NOT all_cooling THEN
    SELECT
      count(*)::integer,
      count(*) FILTER (
        WHERE n.due_at > COALESCE(last_sent_at, '-infinity'::timestamptz)
      )::integer,
      COALESCE(bool_or(
        n.priority = 5
        AND n.due_at > COALESCE(last_sent_at, '-infinity'::timestamptz)
      ), false)
    INTO due_now_count, newly_due, new_overdue_p5
    FROM nodes n
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.sr_enabled
      AND n.state <> 'leech'::node_state
      AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
      AND n.due_at IS NOT NULL
      AND n.due_at <= now();

    SELECT
      EXISTS (
        SELECT 1 FROM notification_events ne2
        WHERE ne2.user_id = p_user
          AND ne2.type = 'opened'::notification_event_type
          AND ne2.created_at > COALESCE(last_sent_at, '-infinity'::timestamptz)
      )
      OR EXISTS (
        SELECT 1 FROM reviews r
        WHERE r.user_id = p_user
          AND r.reviewed_at > COALESCE(last_sent_at, '-infinity'::timestamptz)
      )
    INTO seen_since_last;
  END IF;

  -- Same fire conditions as compute_due_candidates (minus device tokens, gated
  -- above).
  IF NOT all_cooling AND (
    newly_due >= di.threshold
    OR new_overdue_p5
    OR (
      di.renudge_hours > 0
      AND due_now_count > 0
      AND last_sent_at IS NOT NULL
      AND last_sent_at <= now() - make_interval(hours => di.renudge_hours)
      AND NOT seen_since_last
    )
  ) THEN
    candidate := now();
  ELSIF NOT all_cooling
    AND due_now_count > 0
    AND di.renudge_hours > 0
    AND last_sent_at IS NOT NULL
    AND NOT seen_since_last
  THEN
    -- Standing due work; waiting for the re-nudge window.
    candidate := last_sent_at + make_interval(hours => di.renudge_hours);
  ELSIF NOT all_cooling AND newly_due < di.threshold THEN
    -- Need more cards to mature to hit the intensity threshold.
    need_more := GREATEST(di.threshold - newly_due, 1);
    SELECT due_at INTO next_due
    FROM (
      SELECT n.due_at,
             row_number() OVER (ORDER BY n.due_at ASC) AS rn
      FROM nodes n
      WHERE n.bucket_id = ANY(scope_ids)
        AND n.deleted_at IS NULL
        AND n.sr_enabled
        AND n.state <> 'leech'::node_state
        AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
        AND n.due_at IS NOT NULL
        AND n.due_at > now()
    ) ranked
    WHERE rn = need_more;

    IF next_due IS NULL THEN
      -- Fewer upcoming cards than needed for the threshold: use the next
      -- maturity as a progressive ETA (UI updates as more cards appear).
      SELECT min(n.due_at) INTO next_due
      FROM nodes n
      WHERE n.bucket_id = ANY(scope_ids)
        AND n.deleted_at IS NULL
        AND n.sr_enabled
        AND n.state <> 'leech'::node_state
        AND n.state IN ('learning'::node_state, 'review'::node_state, 'relearning'::node_state)
        AND n.due_at IS NOT NULL
        AND n.due_at > now();
    END IF;

    IF next_due IS NOT NULL THEN
      candidate := next_due;
    ELSIF due_now_count > 0 AND di.renudge_hours = 0 THEN
      -- Gentle + standing due below threshold and no future cards: no Drop
      -- until more work appears (matches candidates: no renudge path).
      RETURN NULL;
    END IF;
  END IF;

  -- All buckets cooling, or no candidate yet → soonest cooldown wakeup.
  IF candidate IS NULL THEN
    IF bucket_id IS NULL THEN
      SELECT min(b.cooldown_until) INTO min_cooldown
      FROM active_buckets_for_user(p_user) b
      WHERE b.cooldown_until IS NOT NULL
        AND b.cooldown_until > now();
    ELSE
      SELECT cooldown_until INTO min_cooldown
      FROM buckets
      WHERE id = bucket_id
        AND user_id = p_user
        AND deleted_at IS NULL
        AND cooldown_until IS NOT NULL
        AND cooldown_until > now();
    END IF;

    IF min_cooldown IS NULL THEN
      RETURN NULL;
    END IF;
    candidate := min_cooldown;
  END IF;

  -- Daily cap: if already at max, earliest is next local midnight.
  IF sent_today >= di.max_per_day THEN
    candidate := GREATEST(
      candidate,
      ((date_trunc('day', now() AT TIME ZONE tz) + interval '1 day') AT TIME ZONE tz)
    );
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
    local_now := candidate AT TIME ZONE tz;
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
      ) AT TIME ZONE tz;
    END IF;
  END IF;

  -- If the only path was cooldown-hidden work, keep candidate at wakeup.
  IF bucket_id IS NULL AND NOT all_cooling THEN
    SELECT min(b.cooldown_until) INTO min_cooldown
    FROM active_buckets_for_user(p_user) b
    WHERE b.cooldown_until IS NOT NULL
      AND b.cooldown_until > candidate
      AND NOT EXISTS (
        SELECT 1 FROM active_buckets_for_user(p_user) b2
        WHERE b2.cooldown_until IS NULL OR b2.cooldown_until <= candidate
      );
    IF min_cooldown IS NOT NULL THEN
      candidate := min_cooldown;
    END IF;
  ELSIF bucket_id IS NOT NULL THEN
    SELECT cooldown_until INTO min_cooldown
    FROM buckets
    WHERE id = bucket_id
      AND user_id = p_user
      AND deleted_at IS NULL
      AND cooldown_until > candidate;
    IF min_cooldown IS NOT NULL THEN
      candidate := min_cooldown;
    END IF;
  END IF;

  RETURN candidate;
END;
$$;

REVOKE ALL ON FUNCTION next_drop_time_rpc(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION next_drop_time_rpc(uuid) TO authenticated;
