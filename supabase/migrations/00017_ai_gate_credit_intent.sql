-- Sprint 20 -- AI chat ask-first cooldown credit.
-- Adds a credit-intent argument to ai_gate_consume so the AI-chat composer can
-- ASK before spending a credit during a premium fair-use cooldown, instead of
-- silently auto-spending. Behaviour by intent (premium-cooldown paths only):
--   'auto'  (default)  -> unchanged: deduct if balance >= cost, else 429 ai_cooldown.
--                          Preserves summarize/evaluate/quiz callers verbatim.
--   'ask'              -> never spend; always return 429 ai_cooldown (+cooldown_until)
--                          so the client can show the interstitial [D-UI-1].
--   'spend'            -> explicit credit spend; deduct, or 403 insufficient_credits
--                          when balance is 0 [D-AI-1].
-- Everything else (overview path, native-free path, normal premium allow) is
-- identical to 00005. Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md.

SET search_path = public, extensions;

-- Replace the 2-arg signature with a 3-arg one (default keeps old callers intact).
DROP FUNCTION IF EXISTS ai_gate_consume(uuid, ai_feature);

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

  -- Downgraded -> all AI blocked.
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
      -- ask: surface the interstitial without spending.
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

    -- Not in cooldown: check the rolling hourly burst.
    SELECT count(*) INTO last_hour_cnt
    FROM ai_rate_events
    WHERE user_id = p_user AND created_at >= v_now - interval '1 hour';

    IF last_hour_cnt >= hourly_burst THEN
      -- Trip the cooldown atomically.
      v_cooldown := v_now + (cooldown_hours * interval '1 hour');
      UPDATE profiles SET ai_cooldown_until = v_cooldown WHERE id = p_user;

      -- ask: surface the interstitial without spending.
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

-- Privileges: service-role only (ai-forge runs with the service-role key).
REVOKE ALL ON FUNCTION ai_gate_consume(uuid, ai_feature, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_gate_consume(uuid, ai_feature, text) TO service_role;
