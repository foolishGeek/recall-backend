-- Temporary relaxed free-tier limits while Play/BillDesk payments settle.
-- Flip back with: SELECT public.rollback_limits_to_canon();
-- See recall-backend/docs/LIMITS-ROLLBACK.md

SET search_path = public;

-- ---------------------------------------------------------------------
-- Seed / upsert config keys (relaxed active; canon snapshots for revert)
-- ---------------------------------------------------------------------
INSERT INTO app_config (key, value) VALUES
  ('limits_profile', '"relaxed"'::jsonb),
  ('stacks_free_monthly', '999'::jsonb),
  ('stacks_free_monthly_canon', '2'::jsonb),
  ('buckets_free_writable', '999'::jsonb),
  ('buckets_free_writable_canon', '2'::jsonb),
  ('ai_quota_free_monthly_canon', '50'::jsonb),
  ('ai_overview_free_monthly_canon', '2'::jsonb),
  ('session_size_free_canon', '8'::jsonb),
  ('ai_model_free_canon', '"gemini-1.5-flash"'::jsonb)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, updated_at = now();

-- Raise live free quotas + light free model (Gemini 2.5 Flash-Lite).
UPDATE app_config SET value = '500'::jsonb, updated_at = now()
WHERE key = 'ai_quota_free_monthly';

UPDATE app_config SET value = '50'::jsonb, updated_at = now()
WHERE key = 'ai_overview_free_monthly';

UPDATE app_config SET value = '12'::jsonb, updated_at = now()
WHERE key = 'session_size_free';

UPDATE app_config SET value = '"gemini-2.5-flash-lite"'::jsonb, updated_at = now()
WHERE key = 'ai_model_free';

-- ---------------------------------------------------------------------
-- Stack monthly cap reads app_config (was hardcoded 2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_stack_limit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t     subscription_tier;
  tz    text;
  per   text;
  cnt   integer;
  cap   integer;
BEGIN
  SELECT COALESCE(s.tier, 'free'::subscription_tier), COALESCE(p.timezone, 'UTC')
    INTO t, tz
    FROM profiles p
    LEFT JOIN subscriptions s ON s.user_id = p.id
    WHERE p.id = NEW.user_id;

  IF t = 'premium' THEN
    RETURN NEW;
  END IF;

  cap := app_config_int('stacks_free_monthly', 2);

  per := to_char((now() AT TIME ZONE tz), 'YYYY-MM');

  INSERT INTO user_usage_monthly (user_id, period, stacks_created)
  VALUES (NEW.user_id, per, 1)
  ON CONFLICT (user_id, period)
  DO UPDATE SET stacks_created = user_usage_monthly.stacks_created + 1
  RETURNING stacks_created INTO cnt;

  IF cnt > cap THEN
    RAISE EXCEPTION 'free_tier_stack_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- Writable bucket count for free tier reads app_config (was hardcoded 2)
-- Downgraded stays 3; premium stays 999.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION writable_bucket_count_limit(p_user uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t subscription_tier;
  had_prem boolean;
BEGIN
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
-- One-shot revert to today's canon free caps + free model
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rollback_limits_to_canon()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE app_config SET value = '"canon"'::jsonb, updated_at = now()
  WHERE key = 'limits_profile';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'stacks_free_monthly_canon'),
    '2'::jsonb
  ), updated_at = now()
  WHERE key = 'stacks_free_monthly';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'buckets_free_writable_canon'),
    '2'::jsonb
  ), updated_at = now()
  WHERE key = 'buckets_free_writable';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'ai_quota_free_monthly_canon'),
    '50'::jsonb
  ), updated_at = now()
  WHERE key = 'ai_quota_free_monthly';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'ai_overview_free_monthly_canon'),
    '2'::jsonb
  ), updated_at = now()
  WHERE key = 'ai_overview_free_monthly';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'session_size_free_canon'),
    '8'::jsonb
  ), updated_at = now()
  WHERE key = 'session_size_free';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'ai_model_free_canon'),
    '"gemini-1.5-flash"'::jsonb
  ), updated_at = now()
  WHERE key = 'ai_model_free';
END;
$$;

COMMENT ON FUNCTION rollback_limits_to_canon() IS
  'Restore free-tier caps + ai_model_free to canon snapshots (2 stacks, 2 buckets, 50 AI, 2 overviews, 8 cards, gemini-1.5-flash).';
