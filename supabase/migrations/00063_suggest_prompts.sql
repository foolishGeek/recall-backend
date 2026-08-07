-- Phase 5: bucket-aware starter questions, cached by content fingerprint.
--
-- The model is called only when the bucket's content actually changed. A
-- fingerprint over node count + max(updated_at) + name + sorted tags is
-- byte-identical across requests until something real changes, so a cache hit
-- costs nothing. suggest_prompts is free (does not touch the monthly quota)
-- with its own daily cap.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_suggestions_cache (
  id           bigserial PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  scope_kind   text NOT NULL CHECK (scope_kind IN ('bucket', 'active')),
  scope_id     uuid,                          -- NULL for 'active'
  fingerprint  text NOT NULL,
  suggestions  jsonb NOT NULL,
  model        text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Postgres UNIQUE treats NULLs as distinct, so the active-scope rows (scope_id
-- NULL) need an expression index to stay one-per-fingerprint.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_suggestions_cache_uniq
  ON ai_suggestions_cache (
    user_id,
    scope_kind,
    (COALESCE(scope_id, '00000000-0000-0000-0000-000000000000'::uuid)),
    fingerprint
  );

CREATE INDEX IF NOT EXISTS idx_ai_suggestions_cache_lookup
  ON ai_suggestions_cache (user_id, scope_kind, scope_id, created_at DESC);

ALTER TABLE ai_suggestions_cache ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ai_suggestions_cache_owner ON ai_suggestions_cache;
CREATE POLICY ai_suggestions_cache_owner ON ai_suggestions_cache
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

-- Writing a new fingerprint for a scope deletes older rows so the table
-- cannot grow without bound as the user edits notes.
CREATE OR REPLACE FUNCTION ai_suggestions_cache_put(
  p_user uuid,
  p_scope_kind text,
  p_scope_id uuid,
  p_fingerprint text,
  p_suggestions jsonb,
  p_model text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM ai_suggestions_cache
  WHERE user_id = p_user
    AND scope_kind = p_scope_kind
    AND scope_id IS NOT DISTINCT FROM p_scope_id;

  INSERT INTO ai_suggestions_cache
    (user_id, scope_kind, scope_id, fingerprint, suggestions, model)
  VALUES (p_user, p_scope_kind, p_scope_id, p_fingerprint, p_suggestions, p_model);
END;
$$;

REVOKE ALL ON FUNCTION ai_suggestions_cache_put(uuid, text, uuid, text, jsonb, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION ai_suggestions_fingerprint(
  p_user uuid,
  p_scope_kind text,
  p_scope_id uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_name text := '';
  v_count integer := 0;
  v_max timestamptz;
  v_tags text := '';
BEGIN
  IF p_scope_kind = 'bucket' THEN
    SELECT b.name INTO v_name
    FROM buckets b
    WHERE b.id = p_scope_id AND b.user_id = p_user AND b.deleted_at IS NULL;

    SELECT count(*)::integer, max(n.updated_at)
    INTO v_count, v_max
    FROM nodes n
    WHERE n.bucket_id = p_scope_id AND n.deleted_at IS NULL;

    SELECT string_agg(name, ',' ORDER BY lower(name))
    INTO v_tags
    FROM (
      SELECT DISTINCT t.name
      FROM tags t
      JOIN node_tags nt ON nt.tag_id = t.id
      JOIN nodes n ON n.id = nt.node_id
      WHERE n.bucket_id = p_scope_id AND n.deleted_at IS NULL AND t.user_id = p_user
    ) s;
  ELSE
    SELECT string_agg(b.name, ',' ORDER BY lower(b.name)),
           count(n.*)::integer,
           max(n.updated_at)
    INTO v_name, v_count, v_max
    FROM active_buckets_for_user(p_user) b
    LEFT JOIN nodes n ON n.bucket_id = b.id AND n.deleted_at IS NULL;

    SELECT string_agg(name, ',' ORDER BY lower(name))
    INTO v_tags
    FROM (
      SELECT DISTINCT t.name
      FROM tags t
      JOIN node_tags nt ON nt.tag_id = t.id
      JOIN nodes n ON n.id = nt.node_id
      JOIN active_buckets_for_user(p_user) b ON b.id = n.bucket_id
      WHERE n.deleted_at IS NULL AND t.user_id = p_user
    ) s;
  END IF;

  RETURN md5(
    coalesce(p_scope_kind, '') || '|' ||
    coalesce(p_scope_id::text, '') || '|' ||
    coalesce(v_name, '') || '|' ||
    v_count::text || '|' ||
    coalesce(v_max::text, '') || '|' ||
    coalesce(v_tags, '')
  );
END;
$$;

REVOKE ALL ON FUNCTION ai_suggestions_fingerprint(uuid, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ai_suggestions_fingerprint(uuid, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Policy: free, own daily cap, never touches the monthly requests pool
-- ---------------------------------------------------------------------

INSERT INTO ai_feature_policy (
  profile, feature, access, counter_pool, free_monthly_cap, premium_monthly_cap,
  free_daily_cap, cost_units, min_tier, allow_downgraded, allow_credits,
  counts_toward_burst, temperature, max_tokens,
  client_denial, client_message, client_quota_message, notes
) VALUES
  ('canon', 'suggest_prompts', 'free', NULL, NULL, NULL,
   30, 0, 'free', false, false, false, 0.4, 256,
   'quota', NULL, 'Daily suggestion limit reached',
   'Starter questions. Cached by fingerprint; misses call the model over titles only.'),
  ('relaxed', 'suggest_prompts', 'free', NULL, NULL, NULL,
   100, 0, 'free', true, false, false, 0.4, 256,
   'quota', NULL, 'Daily suggestion limit reached',
   'Starter questions. Cached by fingerprint; misses call the model over titles only.')
ON CONFLICT (profile, feature) DO NOTHING;

-- Teach the free/premium_only/internal branch about free_daily_cap and return
-- sampling settings (needed by suggest_prompts). Body otherwise matches 00060.
CREATE OR REPLACE FUNCTION ai_gate_reserve(
  p_user uuid,
  p_feature text,
  p_credit_intent text DEFAULT 'auto',
  p_client_request_id text DEFAULT NULL,
  p_conversation_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  pol            ai_feature_policy;
  p              profiles%ROWTYPE;
  eff            text;
  per            text;
  today          date;
  used_month     integer := 0;
  used_today     integer := 0;
  cap            integer;
  hourly_burst   integer := app_config_int('ai_premium_hourly_burst', 100);
  cooldown_hours integer := app_config_int('ai_premium_cooldown_hours', 5);
  credit_cost    integer := app_config_int('ai_credit_cost_per_request', 1);
  last_hour_cnt  integer;
  new_balance    integer;
  v_cooldown     timestamptz;
  v_now          timestamptz := now();
  v_hold         integer := 0;
  v_id           uuid;
  prior          ai_requests%ROWTYPE;
BEGIN
  IF NOT app_config_bool('ai_enabled', true) OR app_config_bool('maintenance_mode', false) THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'maintenance');
  END IF;

  pol := ai_policy(p_feature);
  IF pol.feature IS NULL OR NOT pol.enabled OR pol.access = 'disabled' THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'maintenance');
  END IF;

  IF p_client_request_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended(p_user::text || ':' || p_client_request_id, 0));

    SELECT * INTO prior FROM ai_requests
    WHERE user_id = p_user AND client_request_id = p_client_request_id;
    IF FOUND THEN
      IF prior.status = 'succeeded' THEN
        RETURN jsonb_build_object('allowed', true, 'replay', true,
                                  'request_id', prior.id, 'tier', prior.tier,
                                  'response', prior.response);
      END IF;
      IF prior.status = 'reserved' THEN
        RETURN jsonb_build_object('allowed', false, 'error', 'ai_cooldown',
                                  'message', 'A request with this id is still in flight.');
      END IF;
      UPDATE ai_requests SET client_request_id = NULL WHERE id = prior.id;
    END IF;
  END IF;

  SELECT * INTO p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'unauthorized');
  END IF;

  eff := ai_effective_tier(p_user);
  IF eff = 'downgraded' AND NOT pol.allow_downgraded THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
  END IF;
  IF pol.min_tier = 'premium' AND eff <> 'premium' THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
  END IF;

  per   := ai_current_period(p.timezone);
  today := (v_now AT TIME ZONE COALESCE(p.timezone, 'UTC'))::date;

  -- Daily cap applies to every access mode (free features included).
  IF pol.free_daily_cap IS NOT NULL AND eff <> 'premium' THEN
    SELECT count(*) INTO used_today
    FROM ai_requests
    WHERE user_id = p_user AND feature = p_feature AND status <> 'failed'
      AND (reserved_at AT TIME ZONE COALESCE(p.timezone, 'UTC'))::date = today;
    IF used_today >= pol.free_daily_cap THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'ai_quota_exceeded');
    END IF;
  END IF;

  IF pol.access IN ('free', 'premium_only', 'internal') THEN
    INSERT INTO ai_requests (user_id, feature, tier, policy_profile, period,
                             cost_units, client_request_id, conversation_id,
                             expires_at)
    VALUES (p_user, p_feature, ai_tier_label(eff), ai_active_policy_profile(), per,
            0, p_client_request_id, p_conversation_id,
            v_now + interval '10 minutes')
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('allowed', true, 'request_id', v_id,
                              'tier', ai_tier_label(eff),
                              'temperature', pol.temperature,
                              'max_tokens', pol.max_tokens);
  END IF;

  SELECT COALESCE(used, 0) INTO used_month
  FROM ai_usage_counters
  WHERE user_id = p_user AND period = per AND pool = pol.counter_pool;
  used_month := COALESCE(used_month, 0);

  IF eff = 'premium' THEN
    cap := pol.premium_monthly_cap;
    IF cap IS NOT NULL AND used_month + pol.cost_units > cap THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'ai_quota_exceeded');
    END IF;

    IF pol.counts_toward_burst THEN
      IF p.ai_cooldown_until IS NOT NULL AND v_now < p.ai_cooldown_until THEN
        v_cooldown := p.ai_cooldown_until;
      ELSE
        SELECT count(*) INTO last_hour_cnt
        FROM ai_requests
        WHERE user_id = p_user AND counted_toward_burst
          AND status <> 'failed' AND reserved_at >= v_now - interval '1 hour';
        IF last_hour_cnt >= hourly_burst THEN
          v_cooldown := v_now + (cooldown_hours * interval '1 hour');
          UPDATE profiles SET ai_cooldown_until = v_cooldown WHERE id = p_user;
        END IF;
      END IF;
    END IF;

    IF v_cooldown IS NOT NULL THEN
      IF NOT pol.allow_credits OR p_credit_intent = 'ask' THEN
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

      v_hold := credit_cost;
      INSERT INTO ai_credit_ledger (user_id, delta, balance_after, source)
      VALUES (p_user, -credit_cost, new_balance, 'consume');
    END IF;
  ELSE
    cap := pol.free_monthly_cap;
    IF cap IS NOT NULL AND used_month + pol.cost_units > cap THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', CASE WHEN pol.counter_pool = 'overviews'
                      THEN 'overview_quota_exceeded' ELSE 'ai_quota_exceeded' END);
    END IF;
  END IF;

  INSERT INTO ai_usage_counters (user_id, period, pool, used)
  VALUES (p_user, per, pol.counter_pool, pol.cost_units)
  ON CONFLICT (user_id, period, pool)
  DO UPDATE SET used = ai_usage_counters.used + EXCLUDED.used;

  PERFORM ai_mirror_counters(p_user, per);

  INSERT INTO ai_requests (
    user_id, feature, tier, policy_profile, counter_pool, cost_units,
    credit_held, counted_toward_burst, period, client_request_id,
    conversation_id, expires_at
  ) VALUES (
    p_user, p_feature, ai_tier_label(eff), ai_active_policy_profile(),
    pol.counter_pool, pol.cost_units, v_hold, pol.counts_toward_burst, per,
    p_client_request_id, p_conversation_id, v_now + interval '10 minutes'
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('allowed', true, 'request_id', v_id,
                            'tier', ai_tier_label(eff),
                            'temperature', pol.temperature,
                            'max_tokens', pol.max_tokens);
END;
$$;
