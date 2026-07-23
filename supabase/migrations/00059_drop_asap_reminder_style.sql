-- ASAO Reminder style: Drop as soon as one note is ready.
-- Wire: profiles.drop_frequency = 'asap' → drop_intensity threshold 1.
-- Extends the check constraint + drop_debug style label. Owner: Drop UX.

SET search_path = public, extensions;

-- Allow the new wire value on profiles.
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_drop_frequency_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_drop_frequency_check
  CHECK (drop_frequency IN ('daily', '3xwk', 'weekly', 'asap')) NOT VALID;
ALTER TABLE profiles VALIDATE CONSTRAINT profiles_drop_frequency_check;

-- Intensity dial: Gentle / Standard / Persistent / ASAO.
CREATE OR REPLACE FUNCTION drop_intensity(p_frequency text)
RETURNS TABLE (
  threshold integer,
  min_interval_min integer,
  max_per_day integer,
  renudge_hours integer
)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT v.threshold, v.min_interval_min, v.max_per_day, v.renudge_hours
  FROM (
    VALUES
      ('weekly', 8, 240,  3, 0),                                        -- Gentle
      ('3xwk',   5,  60,  6, app_config_int('drop_renudge_hours', 2)),  -- Standard
      ('daily',  3,  30,  8, app_config_int('drop_renudge_hours', 2)),  -- Persistent
      ('asap',   1,  15, 12, app_config_int('drop_renudge_hours', 2))   -- ASAO
  ) AS v(freq, threshold, min_interval_min, max_per_day, renudge_hours)
  WHERE v.freq = COALESCE(NULLIF(p_frequency, ''), 'daily')
  UNION ALL
  -- Fallback to Persistent for any unexpected value.
  SELECT 3, 30, 8, app_config_int('drop_renudge_hours', 2)
  WHERE COALESCE(NULLIF(p_frequency, ''), 'daily')
    NOT IN ('weekly', '3xwk', 'daily', 'asap')
  LIMIT 1;
$$;

-- Keep drop_debug_rpc contract; only add the ASAO label.
CREATE OR REPLACE FUNCTION drop_debug_rpc()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  p profiles%ROWTYPE;
  di record;
  tz text;
  device_tokens_count integer := 0;
  active_bucket_count integer := 0;
  cooling_bucket_count integer := 0;
  scope_ids uuid[];
  all_cooling boolean := false;
  due_pool_size integer := 0;
  newly_due integer := 0;
  new_overdue_p5 boolean := false;
  seen_since_last boolean := false;
  last_sent_at timestamptz;
  sent_today integer := 0;
  in_quiet boolean := false;
  meets_threshold boolean := false;
  min_interval_ok boolean := true;
  under_daily_cap boolean := true;
  would_drop_now boolean := false;
  style_label text;
  reasons text[] := ARRAY[]::text[];
  next_at timestamptz;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO p FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  tz := COALESCE(p.timezone, 'UTC');
  SELECT * INTO di FROM drop_intensity(p.drop_frequency);
  style_label := CASE COALESCE(NULLIF(p.drop_frequency, ''), 'daily')
    WHEN 'weekly' THEN 'Gentle'
    WHEN '3xwk' THEN 'Standard'
    WHEN 'asap' THEN 'ASAO'
    ELSE 'Persistent'
  END;

  SELECT count(*)::integer INTO device_tokens_count
  FROM device_tokens dt WHERE dt.user_id = p_user;

  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE b.cooldown_until IS NOT NULL AND b.cooldown_until > now())::integer,
    array_agg(b.id) FILTER (WHERE b.cooldown_until IS NULL OR b.cooldown_until <= now())
  INTO active_bucket_count, cooling_bucket_count, scope_ids
  FROM active_buckets_for_user(p_user) b;

  all_cooling := active_bucket_count > 0
    AND COALESCE(array_length(scope_ids, 1), 0) = 0;

  SELECT max(created_at) INTO last_sent_at
  FROM notification_events
  WHERE user_id = p_user AND type = 'sent'::notification_event_type;

  SELECT count(*)::integer INTO sent_today
  FROM notification_events ne
  WHERE ne.user_id = p_user
    AND ne.type = 'sent'::notification_event_type
    AND (ne.created_at AT TIME ZONE tz)::date = (now() AT TIME ZONE tz)::date;

  IF COALESCE(array_length(scope_ids, 1), 0) > 0 THEN
    SELECT
      count(*)::integer,
      count(*) FILTER (
        WHERE n.due_at > COALESCE(last_sent_at, '-infinity'::timestamptz)
      )::integer,
      COALESCE(bool_or(
        n.priority = 5
        AND n.due_at > COALESCE(last_sent_at, '-infinity'::timestamptz)
      ), false)
    INTO due_pool_size, newly_due, new_overdue_p5
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

  in_quiet := is_in_quiet_hours(now(), tz, p.quiet_hours_start, p.quiet_hours_end);
  meets_threshold := (newly_due >= di.threshold) OR new_overdue_p5;
  under_daily_cap := sent_today < di.max_per_day;
  min_interval_ok := last_sent_at IS NULL
    OR last_sent_at <= now() - make_interval(mins => di.min_interval_min);

  would_drop_now :=
    COALESCE(p.push_opt_in, false)
    AND device_tokens_count > 0
    AND NOT in_quiet
    AND COALESCE(array_length(scope_ids, 1), 0) > 0
    AND under_daily_cap
    AND min_interval_ok
    AND (
      meets_threshold
      OR (
        di.renudge_hours > 0
        AND due_pool_size > 0
        AND last_sent_at IS NOT NULL
        AND last_sent_at <= now() - make_interval(hours => di.renudge_hours)
        AND NOT seen_since_last
      )
    );

  IF NOT COALESCE(p.push_opt_in, false) THEN
    reasons := reasons || 'Reminders are turned off';
  END IF;
  IF device_tokens_count = 0 THEN
    reasons := reasons || 'This device is not registered for reminders';
  END IF;
  IF active_bucket_count = 0 THEN
    reasons := reasons || 'No active buckets yet';
  ELSIF all_cooling THEN
    reasons := reasons || 'All buckets are in a cooling period';
  END IF;
  IF in_quiet THEN
    reasons := reasons || 'Currently within your quiet hours';
  END IF;
  IF NOT under_daily_cap THEN
    reasons := reasons || 'Reached today''s reminder limit';
  END IF;
  IF NOT min_interval_ok THEN
    reasons := reasons || 'A reminder went out very recently';
  END IF;
  IF COALESCE(array_length(scope_ids, 1), 0) > 0 AND NOT meets_threshold
     AND due_pool_size = 0 THEN
    reasons := reasons || 'No cards are due right now';
  ELSIF COALESCE(array_length(scope_ids, 1), 0) > 0 AND NOT meets_threshold THEN
    reasons := reasons || format('Waiting for %s cards to be ready (%s so far)',
      di.threshold, newly_due);
  END IF;

  next_at := next_drop_time_rpc(NULL);

  RETURN jsonb_build_object(
    'push_opt_in', COALESCE(p.push_opt_in, false),
    'device_token_count', device_tokens_count,
    'reminder_style', style_label,
    'threshold', di.threshold,
    'min_interval_min', di.min_interval_min,
    'max_per_day', di.max_per_day,
    'renudge_hours', di.renudge_hours,
    'active_bucket_count', active_bucket_count,
    'cooling_bucket_count', cooling_bucket_count,
    'all_cooling', all_cooling,
    'due_pool_size', due_pool_size,
    'newly_due', newly_due,
    'new_overdue_p5', new_overdue_p5,
    'meets_threshold', meets_threshold,
    'in_quiet_hours', in_quiet,
    'quiet_hours_start', p.quiet_hours_start,
    'quiet_hours_end', p.quiet_hours_end,
    'sent_today', sent_today,
    'under_daily_cap', under_daily_cap,
    'last_sent_at', last_sent_at,
    'min_interval_ok', min_interval_ok,
    'seen_since_last', seen_since_last,
    'would_drop_now', would_drop_now,
    'next_drop_at', next_at,
    'reasons', to_jsonb(reasons),
    'timezone', tz,
    'checked_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION drop_debug_rpc() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION drop_debug_rpc() TO authenticated;
