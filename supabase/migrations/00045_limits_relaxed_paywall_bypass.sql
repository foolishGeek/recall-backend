-- Temporary-free paywall bypass: when app_config.limits_profile = 'relaxed',
-- uncapped writable buckets for free+downgraded, and skip downgraded AI block.
-- Flip back with: SELECT public.rollback_limits_to_canon(); (no app release).
-- See recall-backend/docs/LIMITS-ROLLBACK.md

SET search_path = public;

-- ---------------------------------------------------------------------
-- Helper: live limits_profile == relaxed (JSON string in app_config.value)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION limits_profile_is_relaxed()
RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT value #>> '{}' FROM app_config WHERE key = 'limits_profile'),
    'canon'
  ) = 'relaxed';
$$;

COMMENT ON FUNCTION limits_profile_is_relaxed() IS
  'True while temporary free is on (payments settling). SQL-only flip via rollback_limits_to_canon().';

-- ---------------------------------------------------------------------
-- Writable bucket count: uncapped for everyone while relaxed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION writable_bucket_count_limit(p_user uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t subscription_tier;
  had_prem boolean;
BEGIN
  IF limits_profile_is_relaxed() THEN
    RETURN 999;
  END IF;

  SELECT COALESCE(s.tier, 'free'::subscription_tier), COALESCE(p.had_premium, false)
    INTO t, had_prem
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = p_user;

  IF t = 'premium'::subscription_tier THEN
    RETURN 999;
  END IF;
  IF had_prem THEN
    RETURN 3;
  END IF;
  RETURN app_config_int('buckets_free_writable', 2);
END;
$$;

-- ---------------------------------------------------------------------
-- ai_gate_check: skip downgraded premium_required while relaxed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_gate_check(p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t           subscription_tier;
  had_prem    boolean;
BEGIN
  IF NOT app_config_bool('ai_enabled', true) OR app_config_bool('maintenance_mode', false) THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'maintenance');
  END IF;

  SELECT COALESCE(s.tier, 'free'::subscription_tier), COALESCE(p.had_premium, false)
    INTO t, had_prem
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = p_user;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'unauthorized');
  END IF;

  -- Downgraded = currently free but previously premium → all AI blocked [B5].
  -- Temporary free (limits_profile=relaxed) opens AI under raised free quotas.
  IF t = 'free'::subscription_tier AND had_prem AND NOT limits_profile_is_relaxed() THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
  END IF;

  RETURN jsonb_build_object('allowed', true, 'tier', t::text);
END;
$$;

-- ---------------------------------------------------------------------
-- ai_gate_consume: same downgraded bypass while relaxed (keep credit intent)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_gate_consume(
  p_user uuid,
  p_feature ai_feature,
  p_credit_intent text DEFAULT 'auto'
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p              profiles%ROWTYPE;
  t              subscription_tier;
  per            text;
  is_overview    boolean := (p_feature = 'evaluate'::ai_feature);
  free_req_cap   integer := app_config_int('ai_quota_free_monthly', 50);
  free_ovr_cap   integer := app_config_int('ai_overview_free_monthly', 2);
  hourly_burst   integer := app_config_int('ai_premium_hourly_burst', 100);
  cooldown_hours integer := app_config_int('ai_premium_cooldown_hours', 5);
  credit_cost    integer := app_config_int('ai_credit_cost_per_request', 1);
  last_hour_cnt  integer;
  new_balance    integer;
  v_cooldown     timestamptz;
  v_now          timestamptz := now();
BEGIN
  IF NOT app_config_bool('ai_enabled', true) OR app_config_bool('maintenance_mode', false) THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'maintenance');
  END IF;

  SELECT * INTO p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'unauthorized');
  END IF;

  SELECT COALESCE(s.tier, 'free'::subscription_tier) INTO t
  FROM subscriptions s WHERE s.user_id = p_user;
  t := COALESCE(t, 'free'::subscription_tier);

  -- Downgraded -> all AI blocked (unless temporary free / relaxed).
  IF t = 'free'::subscription_tier
     AND COALESCE(p.had_premium, false)
     AND NOT limits_profile_is_relaxed() THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
  END IF;

  -- Roll monthly counters on period change.
  per := ai_current_period(p.timezone);
  IF p.ai_usage_period IS DISTINCT FROM per THEN
    UPDATE profiles
    SET ai_usage_period = per, ai_requests_month = 0, ai_overviews_month = 0
    WHERE id = p_user;
    p.ai_requests_month := 0;
    p.ai_overviews_month := 0;
  END IF;

  -- -----------------------------------------------------------------
  -- Overview path (evaluate) -- separate counter, never charged credits.
  -- -----------------------------------------------------------------
  IF is_overview THEN
    IF t = 'premium'::subscription_tier THEN
      RETURN jsonb_build_object('allowed', true, 'tier', t::text);
    END IF;
    IF p.ai_overviews_month >= free_ovr_cap THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'overview_quota_exceeded');
    END IF;
    UPDATE profiles SET ai_overviews_month = ai_overviews_month + 1 WHERE id = p_user;
    RETURN jsonb_build_object('allowed', true, 'tier', t::text);
  END IF;

  -- -----------------------------------------------------------------
  -- Standard AI request path.
  -- -----------------------------------------------------------------
  IF t = 'premium'::subscription_tier THEN
    -- In an active cooldown -> only credits unlock a request.
    IF p.ai_cooldown_until IS NOT NULL AND v_now < p.ai_cooldown_until THEN
      IF p_credit_intent = 'ask' THEN
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'cooldown_until', p.ai_cooldown_until);
      END IF;

      UPDATE profiles
      SET ai_credit_balance = ai_credit_balance - credit_cost
      WHERE id = p_user AND ai_credit_balance >= credit_cost
      RETURNING ai_credit_balance INTO new_balance;

      IF NOT FOUND THEN
        IF p_credit_intent = 'spend' THEN
          RETURN jsonb_build_object('allowed', false, 'error', 'insufficient_credits');
        END IF;
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'cooldown_until', p.ai_cooldown_until);
      END IF;

      INSERT INTO ai_credit_ledger (user_id, delta, balance_after, source)
      VALUES (p_user, -credit_cost, new_balance, 'consume');
      INSERT INTO ai_rate_events (user_id, feature) VALUES (p_user, p_feature);
      UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
      RETURN jsonb_build_object('allowed', true, 'tier', t::text);
    END IF;

    SELECT count(*) INTO last_hour_cnt
    FROM ai_rate_events
    WHERE user_id = p_user AND created_at >= v_now - interval '1 hour';

    IF last_hour_cnt >= hourly_burst THEN
      v_cooldown := v_now + (cooldown_hours * interval '1 hour');
      UPDATE profiles SET ai_cooldown_until = v_cooldown WHERE id = p_user;

      IF p_credit_intent = 'ask' THEN
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'cooldown_until', v_cooldown);
      END IF;

      UPDATE profiles
      SET ai_credit_balance = ai_credit_balance - credit_cost
      WHERE id = p_user AND ai_credit_balance >= credit_cost
      RETURNING ai_credit_balance INTO new_balance;

      IF NOT FOUND THEN
        IF p_credit_intent = 'spend' THEN
          RETURN jsonb_build_object('allowed', false, 'error', 'insufficient_credits');
        END IF;
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'cooldown_until', v_cooldown);
      END IF;

      INSERT INTO ai_credit_ledger (user_id, delta, balance_after, source)
      VALUES (p_user, -credit_cost, new_balance, 'consume');
      INSERT INTO ai_rate_events (user_id, feature) VALUES (p_user, p_feature);
      UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
      RETURN jsonb_build_object('allowed', true, 'tier', t::text);
    END IF;

    INSERT INTO ai_rate_events (user_id, feature) VALUES (p_user, p_feature);
    UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
    RETURN jsonb_build_object('allowed', true, 'tier', t::text);
  END IF;

  -- Native free (and downgraded-while-relaxed).
  IF p.ai_requests_month >= free_req_cap THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'ai_quota_exceeded');
  END IF;
  UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
  RETURN jsonb_build_object('allowed', true, 'tier', t::text);
END;
$$;

REVOKE ALL ON FUNCTION ai_gate_consume(uuid, ai_feature, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_gate_consume(uuid, ai_feature, text) TO service_role;
