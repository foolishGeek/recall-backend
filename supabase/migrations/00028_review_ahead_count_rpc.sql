-- S25 · Empty states: read-only review-ahead pool count + next_drop hardening.
-- review_ahead_count_rpc mirrors generate_stack_rpc(ahead=true) selection logic
-- without writing a stack. next_drop_time_rpc returns NULL when the user has no
-- non-deleted buckets (push off / nothing to schedule).

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- review_ahead_count_rpc: how many cards would review-ahead include?
-- Same eligibility as generate_stack_rpc with ahead = true.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION review_ahead_count_rpc()
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  sp scheduling_params%ROWTYPE;
  t subscription_tier;
  tz text;
  effective_n integer;
  free_cap integer := app_config_int('session_size_free', 8);
  new_today integer;
  new_budget integer;
  scope_ids uuid[];
  v_now timestamptz := now();
  v_ahead boolean := true;
  v_count integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(sub.tier, 'free'::subscription_tier), COALESCE(p.timezone, 'UTC')
    INTO t, tz
  FROM profiles p
  LEFT JOIN subscriptions sub ON sub.user_id = p.id
  WHERE p.id = p_user;
  t := COALESCE(t, 'free'::subscription_tier);
  tz := COALESCE(tz, 'UTC');

  effective_n := COALESCE((SELECT session_size_override FROM profiles WHERE id = p_user), sp.session_size);
  IF t <> 'premium'::subscription_tier THEN
    effective_n := LEAST(effective_n, free_cap);
  END IF;

  SELECT array_agg(b.id ORDER BY b.created_at)
    INTO scope_ids
  FROM buckets b
  WHERE b.user_id = p_user AND b.deleted_at IS NULL;

  IF COALESCE(array_length(scope_ids, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  SELECT count(*) INTO new_today
  FROM reviews r
  WHERE r.user_id = p_user
    AND r.stability_before IS NULL
    AND (r.reviewed_at AT TIME ZONE tz)::date = (v_now AT TIME ZONE tz)::date;

  new_budget := GREATEST(0, LEAST(sp.max_new_per_stack, sp.new_per_day - COALESCE(new_today, 0)));

  WITH raw AS (
    SELECT
      n.id AS node_id,
      n.bucket_id,
      n.state,
      n.priority,
      n.created_at,
      COALESCE(b.daily_cap, sp.max_per_bucket) AS bucket_cap,
      engine_heat(n.stability, n.last_reviewed_at, n.due_at, n.priority, n.difficulty, sp.target_retention, v_now) AS heat_value,
      CASE
        WHEN n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.priority = 5
          AND n.due_at < v_now THEN 0
        WHEN n.state IN ('review'::node_state, 'relearning'::node_state) THEN 1
        ELSE 2
      END AS rank_group,
      (
        abs(hashtext('0:' || n.id::text)::bigint)::numeric
        / 2147483647.0
      ) AS jitter
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.bucket_id = ANY(scope_ids)
      AND n.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
      AND (v_ahead OR b.cooldown_until IS NULL OR b.cooldown_until <= v_now)
      AND (
        n.state = 'new'::node_state
        OR (
          n.state IN ('review'::node_state, 'relearning'::node_state)
          AND n.due_at IS NOT NULL
          AND (v_ahead OR n.due_at <= v_now + (sp.lookahead_hours * interval '1 hour'))
        )
      )
  ),
  new_limited AS (
    SELECT *
    FROM (
      SELECT raw.*, row_number() OVER (ORDER BY priority DESC, created_at ASC, jitter ASC) AS new_rn
      FROM raw
      WHERE state = 'new'::node_state
    ) x
    WHERE new_rn <= new_budget
  ),
  due_cards AS (
    SELECT *
    FROM raw
    WHERE state IN ('review'::node_state, 'relearning'::node_state)
  ),
  combined AS (
    SELECT node_id, bucket_id, state, priority, bucket_cap, heat_value, rank_group,
           (power(greatest(heat_value, 0.0001), sp.temperature) + (jitter * 0.0001)) AS score
    FROM due_cards
    UNION ALL
    SELECT node_id, bucket_id, state, priority, bucket_cap, heat_value, rank_group,
           (priority::numeric + (jitter * 0.0001)) AS score
    FROM new_limited
  ),
  bucket_capped AS (
    SELECT *
    FROM (
      SELECT combined.*,
             row_number() OVER (
               PARTITION BY bucket_id
               ORDER BY rank_group ASC, score DESC, heat_value DESC, node_id
             ) AS bucket_rn
      FROM combined
    ) x
    WHERE bucket_rn <= bucket_cap
  ),
  final_ranked AS (
    SELECT *,
           row_number() OVER (
             ORDER BY rank_group ASC, score DESC, heat_value DESC, node_id
           ) - 1 AS position
    FROM bucket_capped
  )
  SELECT count(*)::integer INTO v_count
  FROM final_ranked
  WHERE position < effective_n;

  RETURN COALESCE(v_count, 0);
END;
$$;

-- ---------------------------------------------------------------------
-- next_drop_time_rpc: NULL when user has no buckets (global scope only).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION next_drop_time_rpc(bucket_id uuid DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  p profiles%ROWTYPE;
  candidate timestamptz;
  local_now timestamp;
  local_minutes integer;
  start_minutes integer;
  end_minutes integer;
  budget integer;
  sent_count integer;
  min_cooldown timestamptz;
  bucket_count integer;
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

  IF bucket_id IS NULL THEN
    SELECT count(*) INTO bucket_count
    FROM buckets
    WHERE user_id = p_user AND deleted_at IS NULL;

    IF COALESCE(bucket_count, 0) = 0 THEN
      RETURN NULL;
    END IF;
  END IF;

  candidate := date_trunc('minute', now());
  candidate := candidate
    + (((15 - (extract(minute FROM candidate)::integer % 15)) % 15) * interval '1 minute');
  IF candidate < now() THEN
    candidate := candidate + interval '15 minutes';
  END IF;

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

  budget := CASE p.drop_frequency
    WHEN 'weekly' THEN app_config_int('drop_budget_weekly', 1)
    WHEN '3xwk' THEN app_config_int('drop_budget_3xwk', 3)
    ELSE app_config_int('drop_budget_daily', 7)
  END;

  SELECT count(*) INTO sent_count
  FROM notification_events
  WHERE user_id = p_user
    AND type = 'sent'::notification_event_type
    AND created_at >= now() - interval '7 days';

  IF sent_count >= budget THEN
    candidate := candidate + CASE p.drop_frequency
      WHEN 'weekly' THEN interval '7 days'
      WHEN '3xwk' THEN interval '3 days'
      ELSE interval '1 day'
    END;
  END IF;

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

REVOKE ALL ON FUNCTION review_ahead_count_rpc() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION review_ahead_count_rpc() TO authenticated;
