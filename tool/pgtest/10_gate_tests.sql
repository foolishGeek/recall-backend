-- Behavioural tests for the AI entitlement gate and request ledger (00060).
--
-- tool/check_sql.py proves this SQL is well-formed. These tests prove it is
-- *correct*, above all the promise the reserve-then-settle design exists to
-- keep: a request that produced no answer costs the user nothing.
--
-- Every check raises on mismatch, so ON_ERROR_STOP fails the whole run.

\set ON_ERROR_STOP on
SET client_min_messages TO notice;

CREATE OR REPLACE FUNCTION pgtest_eq(actual anyelement, expected anyelement, label text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'FAIL %: expected %, got %',
      label, COALESCE(expected::text, 'NULL'), COALESCE(actual::text, 'NULL');
  END IF;
  RAISE NOTICE '  ok  %', label;
END;
$$;

-- A clean user, free tier unless told otherwise.
CREATE OR REPLACE FUNCTION pgtest_user(p_email text, p_tier text DEFAULT 'free',
                                       p_had_premium boolean DEFAULT false)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, confirmed_at) VALUES (uid, p_email, now());
  INSERT INTO profiles (id, had_premium) VALUES (uid, p_had_premium)
    ON CONFLICT (id) DO UPDATE SET had_premium = EXCLUDED.had_premium;
  IF p_tier = 'premium' THEN
    INSERT INTO subscriptions (user_id, tier, expires_at, will_renew)
    VALUES (uid, 'premium'::subscription_tier, now() + interval '30 days', true)
    ON CONFLICT (user_id) DO UPDATE SET tier = 'premium'::subscription_tier;
  END IF;
  RETURN uid;
END;
$$;

-- Units spent from a pool in the user's current period.
CREATE OR REPLACE FUNCTION pgtest_used(p_user uuid, p_pool text)
RETURNS integer
LANGUAGE sql AS $$
  SELECT COALESCE((
    SELECT used FROM ai_usage_counters c
    JOIN profiles p ON p.id = c.user_id
    WHERE c.user_id = p_user AND c.pool = p_pool
      AND c.period = ai_current_period(p.timezone)
  ), 0);
$$;

CREATE OR REPLACE FUNCTION pgtest_credits(p_user uuid)
RETURNS integer
LANGUAGE sql AS $$ SELECT ai_credit_balance FROM profiles WHERE id = p_user; $$;

-- The repo seeds 'relaxed' for dogfooding; the tests assert canon behaviour and
-- switch profiles explicitly where that is the point of the test.
UPDATE app_config SET value = '"canon"'::jsonb WHERE key = 'limits_profile';
SELECT pgtest_eq(ai_active_policy_profile(), 'canon', 'active policy profile is canon');


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a failed request is never charged'
DO $$
DECLARE
  uid uuid := pgtest_user('fail-not-charged@test.local');
  res jsonb;
  rid uuid;
BEGIN
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'starts at zero');

  res := ai_gate_reserve(uid, 'rag_chat');
  PERFORM pgtest_eq((res->>'allowed')::boolean, true, 'reserve is allowed');
  rid := (res->>'request_id')::uuid;
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'reserve holds one unit');

  PERFORM ai_gate_settle(rid, 'failed', p_error_code => 'provider_error');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0,
                    'a failed settle gives the unit back');
  PERFORM pgtest_eq((SELECT status::text FROM ai_requests WHERE id = rid),
                    'failed', 'ledger records the failure');
  PERFORM pgtest_eq((SELECT error_code FROM ai_requests WHERE id = rid),
                    'provider_error', 'ledger records why');
  -- Older clients still read this column, so it has to track the counter.
  PERFORM pgtest_eq((SELECT ai_requests_month FROM profiles WHERE id = uid), 0,
                    'legacy profile counter released too');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a successful request is charged exactly once'
DO $$
DECLARE
  uid uuid := pgtest_user('success-charged@test.local');
  rid uuid;
BEGIN
  rid := (ai_gate_reserve(uid, 'rag_chat')->>'request_id')::uuid;
  PERFORM ai_gate_settle(rid, 'succeeded', p_model => 'gpt-4o-mini',
                         p_provider => 'openai', p_input => 120, p_output => 80);

  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'one unit charged');
  PERFORM pgtest_eq((SELECT ai_requests_month FROM profiles WHERE id = uid), 1,
                    'legacy profile counter mirrored');
  PERFORM pgtest_eq((SELECT input_tokens FROM ai_requests WHERE id = rid), 120,
                    'token counts land on the ledger');

  -- A late duplicate settle must not refund a charged request.
  PERFORM pgtest_eq(ai_gate_settle(rid, 'failed'), false,
                    're-settling a closed request reports no-op');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1,
                    'and does not move the counter');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# quota is enforced at the cap'
DO $$
DECLARE
  uid uuid := pgtest_user('quota-cap@test.local');
  cap integer := (SELECT free_monthly_cap FROM ai_feature_policy
                  WHERE profile = 'canon' AND feature = 'rag_chat');
  res jsonb;
  i   integer;
BEGIN
  FOR i IN 1..cap LOOP
    res := ai_gate_reserve(uid, 'rag_chat');
    IF NOT (res->>'allowed')::boolean THEN
      RAISE EXCEPTION 'FAIL reserve % of % was denied: %', i, cap, res->>'error';
    END IF;
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  END LOOP;
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), cap,
                    'all ' || cap || ' of the allowance are usable');

  res := ai_gate_reserve(uid, 'rag_chat');
  PERFORM pgtest_eq((res->>'allowed')::boolean, false, 'the request past the cap is denied');
  PERFORM pgtest_eq(res->>'error', 'ai_quota_exceeded', 'denied for quota');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), cap, 'a denied reserve charges nothing');
  PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_requests WHERE user_id = uid),
                    cap, 'a denied reserve writes no ledger row');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# an outage cannot burn a monthly allowance'
DO $$
DECLARE
  uid uuid := pgtest_user('outage@test.local');
  cap integer := (SELECT free_monthly_cap FROM ai_feature_policy
                  WHERE profile = 'canon' AND feature = 'rag_chat');
  res jsonb;
  i   integer;
BEGIN
  FOR i IN 1..(cap + 5) LOOP
    res := ai_gate_reserve(uid, 'rag_chat');
    IF NOT (res->>'allowed')::boolean THEN
      RAISE EXCEPTION 'FAIL outage attempt % was denied: %', i, res->>'error';
    END IF;
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'failed',
                           p_error_code => 'provider_timeout');
  END LOOP;
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0,
                    (cap + 5) || ' consecutive failures cost nothing');

  -- The allowance must be genuinely intact, not merely reported as zero.
  FOR i IN 1..cap LOOP
    res := ai_gate_reserve(uid, 'rag_chat');
    IF NOT (res->>'allowed')::boolean THEN
      RAISE EXCEPTION 'FAIL allowance was not intact, denied at % of %: %',
        i, cap, res->>'error';
    END IF;
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  END LOOP;
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), cap,
                    'the whole allowance survived the outage');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a retried client request replays instead of re-charging'
DO $$
DECLARE
  uid uuid := pgtest_user('idempotent@test.local');
  a   jsonb;
  b   jsonb;
BEGIN
  a := ai_gate_reserve(uid, 'rag_chat', 'auto', 'client-key-1');
  PERFORM ai_gate_settle((a->>'request_id')::uuid, 'succeeded',
                         p_response => jsonb_build_object('answer', 'hello'));
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'first attempt charged once');

  b := ai_gate_reserve(uid, 'rag_chat', 'auto', 'client-key-1');
  PERFORM pgtest_eq((b->>'replay')::boolean, true, 'the same key replays');
  PERFORM pgtest_eq(b->'response'->>'answer', 'hello', 'replay returns the stored answer');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'replay charges nothing extra');

  b := ai_gate_reserve(uid, 'rag_chat', 'auto', 'client-key-2');
  PERFORM pgtest_eq((b->>'allowed')::boolean, true, 'a new key is a new request');
  PERFORM ai_gate_settle((b->>'request_id')::uuid, 'succeeded');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 2, 'second key charged once');
END $$;

\echo '# retrying a key whose request failed is allowed through'
DO $$
DECLARE
  uid uuid := pgtest_user('retry-after-fail@test.local');
  a   jsonb;
  b   jsonb;
BEGIN
  a := ai_gate_reserve(uid, 'rag_chat', 'auto', 'retry-key');
  PERFORM ai_gate_settle((a->>'request_id')::uuid, 'failed',
                         p_error_code => 'provider_error');

  b := ai_gate_reserve(uid, 'rag_chat', 'auto', 'retry-key');
  PERFORM pgtest_eq((b->>'allowed')::boolean, true, 'retry after failure is allowed');
  PERFORM pgtest_eq(b ? 'replay', false, 'and is a fresh request, not a replay');
  PERFORM ai_gate_settle((b->>'request_id')::uuid, 'succeeded');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'only the answer is charged');
END $$;

\echo '# a key still in flight is not run twice'
DO $$
DECLARE
  uid uuid := pgtest_user('inflight@test.local');
  a   jsonb;
  b   jsonb;
BEGIN
  a := ai_gate_reserve(uid, 'rag_chat', 'auto', 'inflight-key');
  b := ai_gate_reserve(uid, 'rag_chat', 'auto', 'inflight-key');
  PERFORM pgtest_eq((b->>'allowed')::boolean, false, 'duplicate in-flight is refused');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'and holds only one unit');
  PERFORM ai_gate_settle((a->>'request_id')::uuid, 'succeeded');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a request that never settles is swept back'
DO $$
DECLARE
  uid uuid := pgtest_user('abandoned@test.local');
  rid uuid;
  fresh uuid;
BEGIN
  rid := (ai_gate_reserve(uid, 'rag_chat')->>'request_id')::uuid;
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'held while in flight');

  -- A worker that died before settling.
  UPDATE ai_requests SET expires_at = now() - interval '1 minute' WHERE id = rid;
  PERFORM ai_sweep_stale_requests();

  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'sweeper returns the unit');
  PERFORM pgtest_eq((SELECT status::text FROM ai_requests WHERE id = rid),
                    'released', 'sweeper marks it released');

  -- A still-fresh reservation must survive the sweeper.
  fresh := (ai_gate_reserve(uid, 'rag_chat')->>'request_id')::uuid;
  PERFORM ai_sweep_stale_requests();
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 1, 'in-flight request left alone');
  PERFORM pgtest_eq((SELECT status::text FROM ai_requests WHERE id = fresh),
                    'reserved', 'and is still reserved');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# entitlement: premium-only features are closed to free users'
DO $$
DECLARE
  free_uid uuid := pgtest_user('free-user@test.local');
  prem_uid uuid := pgtest_user('prem-user@test.local', 'premium');
  down_uid uuid := pgtest_user('down-user@test.local', 'free', true);
  chk jsonb;
BEGIN
  PERFORM pgtest_eq(ai_effective_tier(free_uid), 'free', 'free tier resolves');
  PERFORM pgtest_eq(ai_effective_tier(prem_uid), 'premium', 'premium tier resolves');
  PERFORM pgtest_eq(ai_effective_tier(down_uid), 'downgraded', 'downgraded tier resolves');

  chk := ai_gate_check(free_uid, 'quiz_session');
  PERFORM pgtest_eq((chk->>'allowed')::boolean, false, 'free user blocked from quiz_session');
  PERFORM pgtest_eq(chk->>'error', 'premium_required', 'blocked for the right reason');

  chk := ai_gate_check(prem_uid, 'quiz_session');
  PERFORM pgtest_eq((chk->>'allowed')::boolean, true, 'premium user allowed in');

  chk := ai_gate_check(down_uid, 'quiz_session');
  PERFORM pgtest_eq((chk->>'allowed')::boolean, false,
                    'a lapsed subscriber is blocked under canon');

  -- Checking must never move a counter.
  PERFORM pgtest_eq(pgtest_used(prem_uid, 'requests'), 0, 'gate_check is read-only');
END $$;

\echo '# a premium-only reserve is ledgered but costs no quota'
DO $$
DECLARE
  uid uuid := pgtest_user('prem-session@test.local', 'premium');
  res jsonb;
BEGIN
  res := ai_gate_reserve(uid, 'quiz_session');
  PERFORM pgtest_eq((res->>'allowed')::boolean, true, 'premium session allowed');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'entitlement features are free');
  PERFORM pgtest_eq((SELECT cost_units FROM ai_requests
                     WHERE id = (res->>'request_id')::uuid), 0,
                    'ledgered at zero cost');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# counter pools are independent'
DO $$
DECLARE
  uid uuid := pgtest_user('pools@test.local');
  res jsonb;
BEGIN
  res := ai_gate_reserve(uid, 'evaluate');
  PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  PERFORM pgtest_eq(pgtest_used(uid, 'overviews'), 1, 'evaluate hits the overviews pool');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'and leaves chat requests alone');
  PERFORM pgtest_eq((SELECT ai_overviews_month FROM profiles WHERE id = uid), 1,
                    'legacy overview counter mirrored');
END $$;

\echo '# the overview pool reports its own denial code'
DO $$
DECLARE
  uid uuid := pgtest_user('overview-cap@test.local');
  cap integer := (SELECT free_monthly_cap FROM ai_feature_policy
                  WHERE profile = 'canon' AND feature = 'evaluate');
  res jsonb;
  i   integer;
BEGIN
  FOR i IN 1..cap LOOP
    res := ai_gate_reserve(uid, 'evaluate');
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  END LOOP;
  res := ai_gate_reserve(uid, 'evaluate');
  PERFORM pgtest_eq(res->>'error', 'overview_quota_exceeded',
                    'overviews get their own message');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# credits are refunded when the request fails'
DO $$
DECLARE
  uid uuid := pgtest_user('credits@test.local', 'premium');
  res jsonb;
BEGIN
  -- Premium users only need credits once fair-use cooldown bites.
  UPDATE profiles SET ai_cooldown_until = now() + interval '1 hour',
                      ai_credit_balance = 3
  WHERE id = uid;

  res := ai_gate_reserve(uid, 'rag_chat', 'auto');
  PERFORM pgtest_eq((res->>'allowed')::boolean, true, 'a credit unlocks the request');
  PERFORM pgtest_eq(pgtest_credits(uid), 2, 'balance debited while in flight');

  PERFORM ai_gate_settle((res->>'request_id')::uuid, 'failed',
                         p_error_code => 'provider_error');
  PERFORM pgtest_eq(pgtest_credits(uid), 3, 'credit refunded on failure');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'and the unit came back too');

  -- A credit spent on a real answer stays spent.
  res := ai_gate_reserve(uid, 'rag_chat', 'auto');
  PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  PERFORM pgtest_eq(pgtest_credits(uid), 2, 'credit stays spent on success');

  -- The ledger must explain every movement.
  PERFORM pgtest_eq((SELECT sum(delta)::integer FROM ai_credit_ledger WHERE user_id = uid),
                    -1, 'credit ledger nets to the one real spend');
END $$;

\echo '# an empty balance in cooldown is refused, not overdrawn'
DO $$
DECLARE
  uid uuid := pgtest_user('no-credits@test.local', 'premium');
  res jsonb;
BEGIN
  UPDATE profiles SET ai_cooldown_until = now() + interval '1 hour',
                      ai_credit_balance = 0
  WHERE id = uid;

  res := ai_gate_reserve(uid, 'rag_chat', 'spend');
  PERFORM pgtest_eq((res->>'allowed')::boolean, false, 'refused with no credits');
  PERFORM pgtest_eq(res->>'error', 'insufficient_credits', 'and says why');
  PERFORM pgtest_eq(pgtest_credits(uid), 0, 'balance never goes negative');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# an outage cannot push a premium user into cooldown'
DO $$
DECLARE
  uid uuid := pgtest_user('burst@test.local', 'premium');
  res jsonb;
  i   integer;
BEGIN
  UPDATE app_config SET value = '3'::jsonb WHERE key = 'ai_premium_hourly_burst';

  -- Ten failures in a row: none of them should count against fair use.
  FOR i IN 1..10 LOOP
    res := ai_gate_reserve(uid, 'rag_chat');
    IF NOT (res->>'allowed')::boolean THEN
      RAISE EXCEPTION 'FAIL failure % was throttled: %', i, res->>'error';
    END IF;
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'failed',
                           p_error_code => 'provider_timeout');
  END LOOP;
  PERFORM pgtest_eq(true, true, '10 consecutive failures were not throttled');
  PERFORM pgtest_eq((SELECT ai_cooldown_until FROM profiles WHERE id = uid), NULL,
                    'no cooldown from failures alone');

  -- Real answers do count, so the burst limit still applies.
  FOR i IN 1..3 LOOP
    res := ai_gate_reserve(uid, 'rag_chat');
    PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
  END LOOP;
  res := ai_gate_reserve(uid, 'rag_chat', 'ask');
  PERFORM pgtest_eq(res->>'error', 'ai_cooldown', 'genuine burst still throttles');

  UPDATE app_config SET value = '100'::jsonb WHERE key = 'ai_premium_hourly_burst';
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# maintenance and kill switches close the gate'
DO $$
DECLARE
  uid uuid := pgtest_user('killswitch@test.local');
  res jsonb;
BEGIN
  UPDATE app_config SET value = 'false'::jsonb WHERE key = 'ai_enabled';
  res := ai_gate_reserve(uid, 'rag_chat');
  PERFORM pgtest_eq(res->>'error', 'maintenance', 'ai_enabled=false closes the gate');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'and charges nothing');
  UPDATE app_config SET value = 'true'::jsonb WHERE key = 'ai_enabled';

  UPDATE app_config SET value = 'true'::jsonb WHERE key = 'maintenance_mode';
  res := ai_gate_reserve(uid, 'rag_chat');
  PERFORM pgtest_eq(res->>'error', 'maintenance', 'maintenance_mode closes the gate');
  UPDATE app_config SET value = 'false'::jsonb WHERE key = 'maintenance_mode';

  res := ai_gate_reserve(uid, 'rag_chat');
  PERFORM pgtest_eq((res->>'allowed')::boolean, true, 'and reopens afterwards');
  PERFORM ai_gate_settle((res->>'request_id')::uuid, 'succeeded');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# an unknown feature is refused rather than silently allowed'
DO $$
DECLARE
  uid uuid := pgtest_user('unknown-feature@test.local');
  res jsonb;
BEGIN
  res := ai_gate_reserve(uid, 'not_a_real_feature');
  PERFORM pgtest_eq((res->>'allowed')::boolean, false, 'unknown feature denied');
  PERFORM pgtest_eq(pgtest_used(uid, 'requests'), 0, 'and costs nothing');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# switching profile changes policy with no code change'
DO $$
DECLARE
  uid uuid := pgtest_user('relaxed@test.local');
  chk jsonb;
BEGIN
  UPDATE app_config SET value = '"relaxed"'::jsonb WHERE key = 'limits_profile';
  PERFORM pgtest_eq(ai_active_policy_profile(), 'relaxed', 'profile switched');

  -- Caps reach the client through v_ai_policy; gate_check answers only
  -- "is this user entitled", so the two must agree on the active profile.
  PERFORM pgtest_eq((SELECT free_monthly_cap FROM v_ai_policy WHERE feature = 'rag_chat'),
                    500, 'the relaxed cap is what the client would read');

  -- retention_simulate is premium-only under canon, open to all under relaxed.
  chk := ai_gate_check(uid, 'retention_simulate');
  PERFORM pgtest_eq((chk->>'allowed')::boolean, true, 'relaxed opens it to free users');

  UPDATE app_config SET value = '"canon"'::jsonb WHERE key = 'limits_profile';
  chk := ai_gate_check(uid, 'retention_simulate');
  PERFORM pgtest_eq((chk->>'allowed')::boolean, false, 'canon closes it again');
  PERFORM pgtest_eq((SELECT free_monthly_cap FROM v_ai_policy WHERE feature = 'rag_chat'),
                    50, 'and the client-visible cap follows');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# the client-facing policy view tracks the active profile'
DO $$
DECLARE
  n integer;
BEGIN
  SELECT count(*)::integer INTO n FROM v_ai_policy;
  PERFORM pgtest_eq(n, (SELECT count(*)::integer FROM ai_feature_policy
                        WHERE profile = 'canon'),
                    'view exposes exactly the active profile rows');
  PERFORM pgtest_eq((SELECT count(DISTINCT feature)::integer FROM v_ai_policy), n,
                    'one row per feature, no duplicates');
END $$;


DROP FUNCTION pgtest_eq(anyelement, anyelement, text);
DROP FUNCTION pgtest_user(text, text, boolean);
DROP FUNCTION pgtest_used(uuid, text);
DROP FUNCTION pgtest_credits(uuid);

\echo ''
\echo 'ALL GATE TESTS PASSED'
