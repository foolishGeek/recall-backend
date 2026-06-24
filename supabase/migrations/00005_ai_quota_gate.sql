-- Sprint 06 -- AI Forge quota gate + usage logging (server-authoritative).
-- Implements the §3b gate atomically so ai-forge (service-role) is the only
-- place AI quota/credit/cooldown decisions are made. Mobile never decides.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md  ([D-AI-1..4], [CANON §11]).

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- Read a boolean app_config flag (stored as a bare JSON boolean, e.g. 'true').
CREATE OR REPLACE FUNCTION app_config_bool(p_key text, p_default boolean)
RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE((SELECT (value #>> '{}')::boolean FROM app_config WHERE key = p_key), p_default);
$$;

-- Billing period label ('YYYY-MM') in the user's local timezone.
CREATE OR REPLACE FUNCTION ai_current_period(p_tz text)
RETURNS text
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT to_char((now() AT TIME ZONE COALESCE(NULLIF(p_tz, ''), 'UTC')), 'YYYY-MM');
$$;

-- ---------------------------------------------------------------------
-- ai_gate_check: cheap pre-flight (no mutation). maintenance + downgrade.
-- Used by rag_chat before retrieval so an empty corpus stays free [§6].
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
  IF t = 'free'::subscription_tier AND had_prem THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
  END IF;

  RETURN jsonb_build_object('allowed', true, 'tier', t::text);
END;
$$;

-- ---------------------------------------------------------------------
-- ai_gate_consume: the authoritative §3b gate. Mutates counters/credits
-- atomically (profile row locked FOR UPDATE) and returns the decision.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_gate_consume(p_user uuid, p_feature ai_feature)
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

  -- Downgraded → all AI blocked.
  IF t = 'free'::subscription_tier AND COALESCE(p.had_premium, false) THEN
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
  -- Overview path (evaluate) — separate counter, never charged credits.
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
    -- In an active cooldown → only credits unlock a request.
    IF p.ai_cooldown_until IS NOT NULL AND v_now < p.ai_cooldown_until THEN
      UPDATE profiles
      SET ai_credit_balance = ai_credit_balance - credit_cost
      WHERE id = p_user AND ai_credit_balance >= credit_cost
      RETURNING ai_credit_balance INTO new_balance;

      IF NOT FOUND THEN
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'cooldown_until', p.ai_cooldown_until);
      END IF;

      INSERT INTO ai_credit_ledger (user_id, delta, balance_after, source)
      VALUES (p_user, -credit_cost, new_balance, 'consume');
      INSERT INTO ai_rate_events (user_id, feature) VALUES (p_user, p_feature);
      UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
      RETURN jsonb_build_object('allowed', true, 'tier', t::text);
    END IF;

    -- Not in cooldown: check the rolling hourly burst.
    SELECT count(*) INTO last_hour_cnt
    FROM ai_rate_events
    WHERE user_id = p_user AND created_at >= v_now - interval '1 hour';

    IF last_hour_cnt >= hourly_burst THEN
      -- Trip the cooldown atomically, then require a credit for this request.
      UPDATE profiles
      SET ai_cooldown_until = v_now + (cooldown_hours * interval '1 hour')
      WHERE id = p_user;

      UPDATE profiles
      SET ai_credit_balance = ai_credit_balance - credit_cost
      WHERE id = p_user AND ai_credit_balance >= credit_cost
      RETURNING ai_credit_balance INTO new_balance;

      IF NOT FOUND THEN
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'cooldown_until', v_now + (cooldown_hours * interval '1 hour'));
      END IF;

      INSERT INTO ai_credit_ledger (user_id, delta, balance_after, source)
      VALUES (p_user, -credit_cost, new_balance, 'consume');
      INSERT INTO ai_rate_events (user_id, feature) VALUES (p_user, p_feature);
      UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
      RETURN jsonb_build_object('allowed', true, 'tier', t::text);
    END IF;

    -- Normal premium allow.
    INSERT INTO ai_rate_events (user_id, feature) VALUES (p_user, p_feature);
    UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
    RETURN jsonb_build_object('allowed', true, 'tier', t::text);
  END IF;

  -- Native free.
  IF p.ai_requests_month >= free_req_cap THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'ai_quota_exceeded');
  END IF;
  UPDATE profiles SET ai_requests_month = ai_requests_month + 1 WHERE id = p_user;
  RETURN jsonb_build_object('allowed', true, 'tier', t::text);
END;
$$;

-- ---------------------------------------------------------------------
-- ai_log_usage: append token accounting to ai_usage (per user/day/feature).
-- Counters live on profiles (set by the gate); this is the audit trail.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_log_usage(
  p_user uuid,
  p_feature ai_feature,
  p_input bigint,
  p_output bigint,
  p_model text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  tz text;
  d  date;
BEGIN
  SELECT COALESCE(timezone, 'UTC') INTO tz FROM profiles WHERE id = p_user;
  d := (now() AT TIME ZONE COALESCE(tz, 'UTC'))::date;

  INSERT INTO ai_usage (user_id, usage_date, feature, request_count, input_tokens, output_tokens, model)
  VALUES (p_user, d, p_feature, 1, GREATEST(COALESCE(p_input, 0), 0), GREATEST(COALESCE(p_output, 0), 0), p_model)
  ON CONFLICT (user_id, usage_date, feature)
  DO UPDATE SET
    request_count = ai_usage.request_count + 1,
    input_tokens  = ai_usage.input_tokens + EXCLUDED.input_tokens,
    output_tokens = ai_usage.output_tokens + EXCLUDED.output_tokens,
    model         = EXCLUDED.model;
END;
$$;

-- ---------------------------------------------------------------------
-- Privileges: service-role only (ai-forge runs with the service-role key).
-- Never exposed to authenticated/anon — the client cannot self-grant quota.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  app_config_bool(text, boolean),
  ai_current_period(text),
  ai_gate_check(uuid),
  ai_gate_consume(uuid, ai_feature),
  ai_log_usage(uuid, ai_feature, bigint, bigint, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  ai_gate_check(uuid),
  ai_gate_consume(uuid, ai_feature),
  ai_log_usage(uuid, ai_feature, bigint, bigint, text)
TO service_role;
