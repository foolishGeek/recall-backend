-- Phase 1 — AI entitlement policy + request ledger.
--
-- Two problems this fixes.
--
-- 1. Policy lived in code. "Free vs quota vs paywall" was decided in four places:
--    ai_gate_consume (SQL), five open-coded `tier <> premium` checks in Edge
--    Functions, a SQL check for retention, and a third copy in Dart. The gate
--    body itself was pasted three times (00005 -> 00017 -> 00045) and the quota
--    pool was a hardcoded `p_feature = 'evaluate'`. Now every one of those
--    decisions is a row in ai_feature_policy and the gate has no per-feature
--    branch at all: adding or re-tiering a feature is an INSERT/UPDATE.
--
-- 2. Failed requests were charged. The old gate incremented the counter before
--    the model call, so a provider_error burned one of a free user's 50 monthly
--    requests. A refund is not enough - if the isolate is killed the refund never
--    runs. So charging is now reserve -> settle: ai_requests holds the unit, and
--    a sweeper releases anything still reserved past its deadline. A crash can no
--    longer take a user's quota.
--
-- The ledger also becomes the single usage spine. ai_usage stays as a rollup
-- written by settle, the hourly burst is counted from the ledger, and the
-- profiles counters are kept only as a cache for fast UI reads.
--
-- Behaviour is unchanged by this migration: the seeds reproduce today's matrix
-- exactly (free 50 requests + 2 overviews, premium unlimited + 100/hr -> 5h
-- cooldown, downgraded blocked unless relaxed, quiz premium-only).

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Policy: one row per (limits profile, feature).
-- `profile` mirrors app_config.limits_profile, so the temporary-free flip
-- selects a different row set instead of threading `AND NOT relaxed` through
-- branches the way 00045 had to.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_feature_policy (
  profile              text    NOT NULL,
  feature              text    NOT NULL,
  enabled              boolean NOT NULL DEFAULT true,
  -- free         = allowed, nothing counted
  -- metered      = draws from counter_pool
  -- premium_only = entitlement check only, nothing counted
  -- credits_only = must spend a credit
  -- internal     = service-role callers only
  -- disabled     = always refused
  access               text    NOT NULL DEFAULT 'metered',
  counter_pool         text,
  free_monthly_cap     integer,
  premium_monthly_cap  integer,          -- NULL = unlimited
  free_daily_cap       integer,          -- NULL = no daily cap
  cost_units           integer NOT NULL DEFAULT 1,
  min_tier             text    NOT NULL DEFAULT 'free',
  allow_downgraded     boolean NOT NULL DEFAULT false,
  allow_credits        boolean NOT NULL DEFAULT false,
  counts_toward_burst  boolean NOT NULL DEFAULT false,
  temperature          numeric(3,2) NOT NULL DEFAULT 0.2,
  max_tokens           integer NOT NULL DEFAULT 2048,
  -- How the app should present a block, so moving a feature between "upsell"
  -- and "coming soon" is a row update rather than a Dart change.
  client_denial        text    NOT NULL DEFAULT 'paywall',
  client_message       text,             -- shown when the tier itself blocks
  client_quota_message text,             -- shown when the cap is exhausted
  notes                text,
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile, feature),
  CONSTRAINT ai_feature_policy_access_chk
    CHECK (access IN ('free','metered','premium_only','credits_only','internal','disabled')),
  CONSTRAINT ai_feature_policy_min_tier_chk
    CHECK (min_tier IN ('free','premium')),
  CONSTRAINT ai_feature_policy_client_denial_chk
    CHECK (client_denial IN ('paywall','quota','wip')),
  -- A metered feature without a pool would silently count nothing.
  CONSTRAINT ai_feature_policy_pool_chk
    CHECK (access <> 'metered' OR counter_pool IS NOT NULL)
);

DROP TRIGGER IF EXISTS set_ai_feature_policy_updated_at ON ai_feature_policy;
CREATE TRIGGER set_ai_feature_policy_updated_at BEFORE UPDATE ON ai_feature_policy
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE ai_feature_policy ENABLE ROW LEVEL SECURITY;

-- Readable by signed-in clients so the mobile TierGate stops re-encoding the
-- rules in Dart. Contains no user data. Writes are service-role only.
DROP POLICY IF EXISTS ai_feature_policy_read ON ai_feature_policy;
CREATE POLICY ai_feature_policy_read ON ai_feature_policy
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------
-- Seeds. These reproduce today's behaviour exactly - the gate rewrite below
-- must be a no-op before anything is reconfigured.
--
--   canon:   free 50 requests + 2 overviews, downgraded blocked, quiz premium.
--   relaxed: raised free caps and downgraded allowed (matches 00045 + the
--            mobile AppLimits.relaxed constants), quiz still premium-only.
--
-- link_preview is deliberately absent: it is a non-LLM Edge Function and the
-- enum value was never used by ai-forge. No policy row means the gate refuses
-- it, which is the removal that matters. The Postgres enum value itself is left
-- alone because ai_usage and ai_rate_events are typed on it and rewriting both
-- tables is not worth it.
-- ---------------------------------------------------------------------
-- client_denial / client_message / client_quota_message reproduce the strings
-- TierGate hard-coded, so the app renders copy instead of deciding it.
INSERT INTO ai_feature_policy (
  profile, feature, access, counter_pool, free_monthly_cap, premium_monthly_cap,
  cost_units, min_tier, allow_downgraded, allow_credits, counts_toward_burst,
  client_denial, client_message, client_quota_message, notes
) VALUES
  -- canon -------------------------------------------------------------
  ('canon','embed',            'metered','requests', 50, NULL, 1,'free',   false,false,true,
   'paywall', NULL, NULL,
   'Internal pipeline; silently skipped when denied [D-AI-3].'),
  ('canon','rag_chat',         'metered','requests', 50, NULL, 1,'free',   false,true, true,
   'paywall', 'AI unavailable — resubscribe to continue', 'Monthly AI limit reached', NULL),
  ('canon','summarize',        'metered','requests', 50, NULL, 1,'free',   false,true, true,
   'paywall', 'AI unavailable — resubscribe to continue', 'Monthly AI limit reached', NULL),
  ('canon','evaluate',         'metered','overviews', 2, NULL, 1,'free',   false,false,false,
   'paywall', NULL, 'Monthly overview limit reached',
   'Separate pool; never charged credits and never trips the burst [D-AI-2].'),
  ('canon','quiz_generate',    'metered','requests', 50, NULL, 1,'premium',false,true, true,
   'wip', 'Quiz is in progress for Premium.', 'Monthly AI limit reached', NULL),
  ('canon','quiz_grade',       'metered','requests', 50, NULL, 1,'premium',false,true, true,
   'wip', 'Quiz is in progress for Premium.', 'Monthly AI limit reached', NULL),
  ('canon','retention_simulate','premium_only',NULL, NULL,NULL, 0,'premium',false,false,false,
   'paywall', NULL, NULL,
   'Entitlement only - no model call, nothing metered.'),
  ('canon','quiz_session',     'premium_only',NULL, NULL,NULL, 0,'premium',false,false,false,
   'wip', 'Quiz is in progress for Premium.', NULL,
   'Start/answer/complete a quiz. Entitlement only; generation is billed separately.'),
  -- relaxed -----------------------------------------------------------
  ('relaxed','embed',            'metered','requests', 500, NULL, 1,'free',   true, false,true,
   'paywall', NULL, NULL, NULL),
  ('relaxed','rag_chat',         'metered','requests', 500, NULL, 1,'free',   true, true, true,
   'paywall', 'AI unavailable — resubscribe to continue', 'Monthly AI limit reached', NULL),
  ('relaxed','summarize',        'metered','requests', 500, NULL, 1,'free',   true, true, true,
   'paywall', 'AI unavailable — resubscribe to continue', 'Monthly AI limit reached', NULL),
  ('relaxed','evaluate',         'metered','overviews', 50, NULL, 1,'free',   true, false,false,
   'paywall', NULL, 'Monthly overview limit reached', NULL),
  ('relaxed','quiz_generate',    'metered','requests', 500, NULL, 1,'premium',true, true, true,
   'wip', 'Quiz is in progress for Premium.', 'Monthly AI limit reached',
   'Quiz stays premium-only even while relaxed (client WIP).'),
  ('relaxed','quiz_grade',       'metered','requests', 500, NULL, 1,'premium',true, true, true,
   'wip', 'Quiz is in progress for Premium.', 'Monthly AI limit reached', NULL),
  ('relaxed','retention_simulate','premium_only',NULL, NULL,NULL, 0,'free',   true, false,false,
   'paywall', NULL, NULL,
   'Relaxed opens retention to everyone, matching assertPremiumAccess.'),
  ('relaxed','quiz_session',     'premium_only',NULL, NULL,NULL, 0,'premium',true, false,false,
   'wip', 'Quiz is in progress for Premium.', NULL,
   'Stays premium-only while relaxed, matching quiz_generate.')
ON CONFLICT (profile, feature) DO NOTHING;

-- ---------------------------------------------------------------------
-- Counters: generic (user, period, pool) so a new pool needs no schema change.
-- The two legacy profiles columns are mirrored for back-compat because the app
-- reads them directly for the "N of 50 used" label [D-AI-4].
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_usage_counters (
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  period  text NOT NULL,                    -- 'YYYY-MM' in the user's timezone
  pool    text NOT NULL,
  used    integer NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, period, pool)
);

ALTER TABLE ai_usage_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_usage_counters_owner_select ON ai_usage_counters;
CREATE POLICY ai_usage_counters_owner_select ON ai_usage_counters
  FOR SELECT USING (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- The ledger. One append-only row per request, reserved before any model call
-- and settled after. This is the only place that decides whether a user was
-- charged, and it is what makes a crash safe.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_request_status') THEN
    CREATE TYPE ai_request_status AS ENUM ('reserved','succeeded','failed','released');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS ai_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  feature           text NOT NULL,
  status            ai_request_status NOT NULL DEFAULT 'reserved',
  tier              text,
  policy_profile    text,
  counter_pool      text,
  cost_units        integer NOT NULL DEFAULT 0,
  credit_held       integer NOT NULL DEFAULT 0,
  counted_toward_burst boolean NOT NULL DEFAULT false,
  period            text,
  client_request_id text,
  conversation_id   uuid,
  model             text,
  provider          text,
  input_tokens      integer NOT NULL DEFAULT 0,
  output_tokens     integer NOT NULL DEFAULT 0,
  latency_ms        integer,
  error_code        text,
  -- Short-lived idempotency cache, not an archive: the sweeper clears it.
  response          jsonb,
  reserved_at       timestamptz NOT NULL DEFAULT now(),
  settled_at        timestamptz,
  expires_at        timestamptz NOT NULL DEFAULT now() + interval '10 minutes'
);

-- Idempotency: a client retry after a timeout must not pay twice.
CREATE UNIQUE INDEX IF NOT EXISTS ai_requests_client_key
  ON ai_requests (user_id, client_request_id)
  WHERE client_request_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ai_requests_user_created
  ON ai_requests (user_id, reserved_at DESC);
CREATE INDEX IF NOT EXISTS ai_requests_burst
  ON ai_requests (user_id, reserved_at DESC)
  WHERE counted_toward_burst AND status <> 'failed';
CREATE INDEX IF NOT EXISTS ai_requests_sweep
  ON ai_requests (expires_at)
  WHERE status = 'reserved';

ALTER TABLE ai_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_requests_owner_select ON ai_requests;
CREATE POLICY ai_requests_owner_select ON ai_requests
  FOR SELECT USING (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_active_policy_profile()
RETURNS text
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT value #>> '{}' FROM app_config WHERE key = 'limits_profile'),
    'canon'
  );
$$;

-- What the mobile TierGate reads instead of re-encoding the rules in Dart.
-- Exposes the active profile only, so switching canon <-> relaxed stays a
-- server-side decision the app never re-derives. No user data.
CREATE OR REPLACE VIEW v_ai_policy AS
  SELECT feature, enabled, access, counter_pool,
         free_monthly_cap, premium_monthly_cap, free_daily_cap,
         cost_units, min_tier, allow_downgraded, allow_credits,
         client_denial, client_message, client_quota_message
  FROM ai_feature_policy
  WHERE profile = ai_active_policy_profile();

GRANT SELECT ON v_ai_policy TO authenticated, service_role;

-- Resolves the policy row, falling back to canon when the active profile has no
-- row for this feature, so a half-seeded profile cannot open a feature by accident.
CREATE OR REPLACE FUNCTION ai_policy(p_feature text)
RETURNS ai_feature_policy
LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE
  v_profile text := ai_active_policy_profile();
  v_row     ai_feature_policy;
BEGIN
  SELECT * INTO v_row FROM ai_feature_policy
  WHERE profile = v_profile AND feature = p_feature;

  IF NOT FOUND AND v_profile <> 'canon' THEN
    SELECT * INTO v_row FROM ai_feature_policy
    WHERE profile = 'canon' AND feature = p_feature;
  END IF;

  RETURN v_row;
END;
$$;

-- Effective tier: 'premium' | 'free' | 'downgraded'.
CREATE OR REPLACE FUNCTION ai_effective_tier(p_user uuid)
RETURNS text
LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE
  t        subscription_tier;
  had_prem boolean;
BEGIN
  SELECT COALESCE(s.tier, 'free'::subscription_tier), COALESCE(p.had_premium, false)
    INTO t, had_prem
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = p_user;

  IF NOT FOUND THEN RETURN NULL; END IF;
  IF t = 'premium'::subscription_tier THEN RETURN 'premium'; END IF;
  IF had_prem THEN RETURN 'downgraded'; END IF;
  RETURN 'free';
END;
$$;

-- The wire contract has always been 'free' | 'premium'; downgraded users are
-- reported as free so existing clients keep working.
CREATE OR REPLACE FUNCTION ai_tier_label(p_effective text)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE WHEN p_effective = 'premium' THEN 'premium' ELSE 'free' END;
$$;

-- Keeps the two legacy profiles columns in step with ai_usage_counters so the
-- app's "N of 50 used" label keeps working without reading the new table.
CREATE OR REPLACE FUNCTION ai_mirror_counters(p_user uuid, p_period text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE profiles SET
    ai_usage_period    = p_period,
    ai_requests_month  = COALESCE((SELECT used FROM ai_usage_counters
                                   WHERE user_id = p_user AND period = p_period
                                     AND pool = 'requests'), 0),
    ai_overviews_month = COALESCE((SELECT used FROM ai_usage_counters
                                   WHERE user_id = p_user AND period = p_period
                                     AND pool = 'overviews'), 0)
  WHERE id = p_user;
$$;

-- ---------------------------------------------------------------------
-- ai_gate_check: cheap pre-flight, no mutation. Generic - every rule comes
-- from the policy row, so there are no per-feature branches.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_gate_check(p_user uuid, p_feature text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  pol ai_feature_policy;
  eff text;
BEGIN
  IF NOT app_config_bool('ai_enabled', true) OR app_config_bool('maintenance_mode', false) THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'maintenance');
  END IF;

  eff := ai_effective_tier(p_user);
  IF eff IS NULL THEN
    RETURN jsonb_build_object('allowed', false, 'error', 'unauthorized');
  END IF;

  IF p_feature IS NOT NULL THEN
    pol := ai_policy(p_feature);
    IF pol.feature IS NULL OR NOT pol.enabled OR pol.access = 'disabled' THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'maintenance',
                                'tier', ai_tier_label(eff));
    END IF;
    IF eff = 'downgraded' AND NOT pol.allow_downgraded THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
    END IF;
    IF pol.min_tier = 'premium' AND eff <> 'premium' THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
    END IF;
  ELSIF eff = 'downgraded' AND ai_active_policy_profile() <> 'relaxed' THEN
    -- Featureless legacy call: keep the blanket downgrade block from 00045.
    RETURN jsonb_build_object('allowed', false, 'error', 'premium_required');
  END IF;

  RETURN jsonb_build_object('allowed', true, 'tier', ai_tier_label(eff));
END;
$$;

-- Back-compat overload for code deployed before this migration.
CREATE OR REPLACE FUNCTION ai_gate_check(p_user uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT ai_gate_check(p_user, NULL::text);
$$;

-- ---------------------------------------------------------------------
-- ai_gate_reserve: the authoritative gate. Holds a unit (or a credit) and
-- returns a request id. Nothing is committed until ai_gate_settle says the
-- work produced an answer.
-- ---------------------------------------------------------------------
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

  -- Idempotent replay: a retry of a request we already answered returns the
  -- stored response instead of charging again.
  IF p_client_request_id IS NOT NULL THEN
    -- Serialise duplicates that arrive together; without this both callers see
    -- "not found" and the second one dies on the unique index instead of
    -- replaying. Released at commit.
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
      -- A previous attempt failed; let this one through under a fresh id.
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

  -- Entitlement-only features cost nothing; still ledgered for visibility.
  IF pol.access IN ('free', 'premium_only', 'internal') THEN
    INSERT INTO ai_requests (user_id, feature, tier, policy_profile, period,
                             cost_units, client_request_id, conversation_id,
                             expires_at)
    VALUES (p_user, p_feature, ai_tier_label(eff), ai_active_policy_profile(), per,
            0, p_client_request_id, p_conversation_id,
            v_now + interval '10 minutes')
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('allowed', true, 'request_id', v_id,
                              'tier', ai_tier_label(eff));
  END IF;

  -- ---- metered / credits_only -----------------------------------------
  SELECT COALESCE(used, 0) INTO used_month
  FROM ai_usage_counters
  WHERE user_id = p_user AND period = per AND pool = pol.counter_pool;
  used_month := COALESCE(used_month, 0);

  IF pol.free_daily_cap IS NOT NULL THEN
    SELECT count(*) INTO used_today
    FROM ai_requests
    WHERE user_id = p_user AND feature = p_feature AND status <> 'failed'
      AND (reserved_at AT TIME ZONE COALESCE(p.timezone, 'UTC'))::date = today;
    IF used_today >= pol.free_daily_cap AND eff <> 'premium' THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'ai_quota_exceeded');
    END IF;
  END IF;

  IF eff = 'premium' THEN
    cap := pol.premium_monthly_cap;
    IF cap IS NOT NULL AND used_month + pol.cost_units > cap THEN
      RETURN jsonb_build_object('allowed', false, 'error', 'ai_quota_exceeded');
    END IF;

    -- Fair-use: an active cooldown, or tripping the hourly burst, means only a
    -- credit unlocks this request. Failed requests are excluded from the count
    -- so a provider outage can no longer push a user into cooldown.
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

  -- Hold the unit. Released again by settle/sweep if no answer is produced.
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

-- ---------------------------------------------------------------------
-- ai_gate_settle: commit or release the hold. 'failed' gives everything back -
-- a user is never charged for a request that produced no answer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_gate_settle(
  p_request uuid,
  p_status text,
  p_model text DEFAULT NULL,
  p_provider text DEFAULT NULL,
  p_input integer DEFAULT 0,
  p_output integer DEFAULT 0,
  p_latency_ms integer DEFAULT NULL,
  p_error_code text DEFAULT NULL,
  p_response jsonb DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r           ai_requests%ROWTYPE;
  new_balance integer;
  ok          boolean;
BEGIN
  SELECT * INTO r FROM ai_requests WHERE id = p_request FOR UPDATE;
  IF NOT FOUND OR r.status <> 'reserved' THEN
    RETURN false;     -- already settled or swept; settling twice is a no-op
  END IF;

  IF p_status = 'succeeded' THEN
    UPDATE ai_requests SET
      status = 'succeeded', model = p_model, provider = p_provider,
      input_tokens = GREATEST(COALESCE(p_input, 0), 0),
      output_tokens = GREATEST(COALESCE(p_output, 0), 0),
      latency_ms = p_latency_ms, response = p_response, settled_at = now()
    WHERE id = p_request;

    -- ai_usage stays as the daily rollup, now written from one place.
    IF r.feature = ANY (ARRAY['embed','rag_chat','summarize','evaluate','quiz_generate','quiz_grade']) THEN
      PERFORM ai_log_usage(r.user_id, r.feature::ai_feature,
                           COALESCE(p_input, 0)::bigint, COALESCE(p_output, 0)::bigint, p_model);
    END IF;
    RETURN true;
  END IF;

  -- Failure or release: hand back the counter unit and any held credit.
  IF r.counter_pool IS NOT NULL AND r.cost_units > 0 THEN
    UPDATE ai_usage_counters
    SET used = GREATEST(used - r.cost_units, 0)
    WHERE user_id = r.user_id AND period = r.period AND pool = r.counter_pool;
    PERFORM ai_mirror_counters(r.user_id, r.period);
  END IF;

  IF r.credit_held > 0 THEN
    UPDATE profiles SET ai_credit_balance = ai_credit_balance + r.credit_held
    WHERE id = r.user_id
    RETURNING ai_credit_balance INTO new_balance;

    INSERT INTO ai_credit_ledger (user_id, delta, balance_after, source)
    VALUES (r.user_id, r.credit_held, new_balance, 'refund');
  END IF;

  UPDATE ai_requests SET
    status = CASE WHEN p_status = 'released' THEN 'released'::ai_request_status
                  ELSE 'failed'::ai_request_status END,
    error_code = p_error_code, latency_ms = p_latency_ms,
    model = p_model, provider = p_provider, credit_held = 0, settled_at = now()
  WHERE id = p_request;

  GET DIAGNOSTICS ok = ROW_COUNT;
  RETURN ok;
END;
$$;

-- ---------------------------------------------------------------------
-- The sweeper. This is the piece that makes the guarantee hold when an Edge
-- Function is killed mid-flight and settle never runs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_sweep_stale_requests()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r       ai_requests%ROWTYPE;
  swept   integer := 0;
BEGIN
  FOR r IN
    SELECT * FROM ai_requests
    WHERE status = 'reserved' AND expires_at < now()
    ORDER BY expires_at
    LIMIT 500
  LOOP
    PERFORM ai_gate_settle(r.id, 'released', NULL, NULL, 0, 0, NULL, 'abandoned', NULL);
    swept := swept + 1;
  END LOOP;

  -- The stored response is only an idempotency cache; expire it quickly.
  UPDATE ai_requests SET response = NULL
  WHERE response IS NOT NULL AND settled_at < now() - interval '6 hours';

  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('ai-sweep-stale-requests', 'ok', 'released=' || swept);
  RETURN swept;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('ai-sweep-stale-requests', 'error', SQLERRM);
  RETURN swept;
END;
$$;

DO $$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'ai-sweep-stale-requests';
  PERFORM cron.schedule(
    'ai-sweep-stale-requests',
    '*/5 * * * *',
    $cron$ SELECT public.ai_sweep_stale_requests(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping ai-sweep-stale-requests schedule';
END;
$$;

-- ---------------------------------------------------------------------
-- Back-compat: ai_gate_consume is kept as reserve + immediate settle so code
-- deployed before this migration keeps working during the rollout window. It
-- does NOT get the never-charge-on-failure guarantee - callers must move to
-- reserve/settle to get that.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_gate_consume(
  p_user uuid,
  p_feature ai_feature,
  p_credit_intent text DEFAULT 'auto'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  res jsonb;
BEGIN
  res := ai_gate_reserve(p_user, p_feature::text, p_credit_intent, NULL, NULL);
  IF (res->>'allowed')::boolean AND (res->>'request_id') IS NOT NULL THEN
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  END IF;
  RETURN res - 'request_id' - 'temperature' - 'max_tokens';
END;
$$;

-- ---------------------------------------------------------------------
-- Privileges: service-role only. A client can never self-grant quota.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  ai_active_policy_profile(),
  ai_policy(text),
  ai_effective_tier(uuid),
  ai_tier_label(text),
  ai_gate_check(uuid, text),
  ai_gate_check(uuid),
  ai_gate_reserve(uuid, text, text, text, uuid),
  ai_gate_settle(uuid, text, text, text, integer, integer, integer, text, jsonb),
  ai_mirror_counters(uuid, text),
  ai_sweep_stale_requests(),
  ai_gate_consume(uuid, ai_feature, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  ai_gate_check(uuid, text),
  ai_gate_check(uuid),
  ai_gate_reserve(uuid, text, text, text, uuid),
  ai_gate_settle(uuid, text, text, text, integer, integer, integer, text, jsonb),
  ai_sweep_stale_requests(),
  ai_gate_consume(uuid, ai_feature, text)
TO service_role;

-- Backfill the new counters from the cached profiles columns so the cutover
-- does not hand every existing user a fresh allowance.
INSERT INTO ai_usage_counters (user_id, period, pool, used)
SELECT id, ai_usage_period, 'requests', ai_requests_month
FROM profiles
WHERE ai_usage_period IS NOT NULL AND COALESCE(ai_requests_month, 0) > 0
ON CONFLICT (user_id, period, pool) DO NOTHING;

INSERT INTO ai_usage_counters (user_id, period, pool, used)
SELECT id, ai_usage_period, 'overviews', ai_overviews_month
FROM profiles
WHERE ai_usage_period IS NOT NULL AND COALESCE(ai_overviews_month, 0) > 0
ON CONFLICT (user_id, period, pool) DO NOTHING;

-- app_config keys the provider layer reads. ai_model_embed was already read by
-- the embed pipeline with a hard-coded default and never had a row.
INSERT INTO app_config (key, value) VALUES
  ('ai_model_embed', '"text-embedding-3-small"'::jsonb),
  ('ai_provider_timeout_ms', '45000'::jsonb)
ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE ai_feature_policy IS
  'Single source of truth for AI entitlement. Free vs quota vs paywall per feature is a row here, not a code branch.';
COMMENT ON TABLE ai_requests IS
  'Append-only AI request ledger. Reserved before the model call, settled after; a failed or swept request is never charged.';
