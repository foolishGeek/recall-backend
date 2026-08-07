#!/usr/bin/env bash
# Concurrency tests for the AI gate. A single psql session cannot show these:
# they need real parallel connections racing on the same user.
#
# What matters is that the counter arithmetic stays exact under load -- no lost
# holds, no double charges, and no overshooting the cap when a crowd of requests
# arrives at once. Invoked by tool/run_migrations.sh with PG* already exported.

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}"
DB="${PGTEST_DB:-recall_test}"
q() { "$PGBIN/psql" -v ON_ERROR_STOP=1 -qtAX -d "$DB" -c "$1"; }

pass=0
check() { # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    printf '  ok  %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; exit 1
  fi
}

q "UPDATE app_config SET value = '\"canon\"'::jsonb WHERE key = 'limits_profile';" >/dev/null

mkuser() { # mkuser <email> -> uuid
  q "WITH u AS (
       INSERT INTO auth.users (id, email, confirmed_at)
       VALUES (gen_random_uuid(), '$1', now()) RETURNING id
     )
     INSERT INTO profiles (id) SELECT id FROM u RETURNING id;"
}

used() { q "SELECT COALESCE((SELECT used FROM ai_usage_counters
                             WHERE user_id='$1' AND pool='requests'),0);"; }

CAP=$(q "SELECT free_monthly_cap FROM ai_feature_policy
         WHERE profile='canon' AND feature='rag_chat';")

# One reserve (+optional settle) on its own connection, classified by what the
# gate actually did. RESERVED is the only outcome that can cost the user
# anything; REPLAY returns a stored answer and DENIED returns nothing.
attempt() { # attempt <uid> <settle-status|none> [client_key]
  local uid="$1" settle="$2" key="${3:-}" keyarg="NULL"
  [[ -n "$key" ]] && keyarg="'$key'"
  # The outcome comes back on stderr as a WARNING, so stderr must stay attached.
  "$PGBIN/psql" -qtAX -d "$DB" <<SQL || echo ERROR
DO \$\$
DECLARE res jsonb;
BEGIN
  res := ai_gate_reserve('$uid', 'rag_chat', 'auto', $keyarg);
  IF NOT (res->>'allowed')::boolean THEN
    RAISE WARNING 'DENIED';
  ELSIF COALESCE((res->>'replay')::boolean, false) THEN
    RAISE WARNING 'REPLAY';
  ELSE
    IF '$settle' <> 'none' THEN
      PERFORM ai_gate_settle((res->>'request_id')::uuid, '$settle',
                             p_error_code => 'provider_error',
                             p_response => '{"answer":"x"}'::jsonb);
    END IF;
    RAISE WARNING 'RESERVED';
  END IF;
END \$\$;
SQL
}

# Fires n attempts at once; sets RESERVED / REPLAY / DENIED to the tallies.
race() { # race <n> <uid> <settle> [key]
  local n="$1"; shift
  local out; out=$(mktemp)
  local i
  for ((i = 0; i < n; i++)); do
    attempt "$@" >>"$out" 2>&1 &
  done
  wait
  RESERVED=$(grep -c RESERVED "$out" || true)
  REPLAY=$(grep -c REPLAY "$out" || true)
  DENIED=$(grep -c DENIED "$out" || true)
  rm -f "$out"
}

echo
echo '# 24 simultaneous successful requests charge exactly 24'
U=$(mkuser 'conc-success@test.local')
race 24 "$U" succeeded
check "all 24 went through" "$RESERVED" 24
check "counter is exactly 24" "$(used "$U")" 24
check "ledger holds 24 answers" \
  "$(q "SELECT count(*) FROM ai_requests WHERE user_id='$U' AND status='succeeded';")" 24

echo
echo '# 24 simultaneous failures charge nothing'
U=$(mkuser 'conc-failure@test.local')
race 24 "$U" failed
check "all 24 were attempted" "$RESERVED" 24
check "counter is back to zero" "$(used "$U")" 0
check "legacy counter is back to zero" \
  "$(q "SELECT ai_requests_month FROM profiles WHERE id='$U';")" 0

echo
echo '# a double-tapped retry key is only ever charged once'
U=$(mkuser 'conc-idempotent@test.local')
race 12 "$U" succeeded 'same-key'
check "only one of 12 duplicates reached the model" "$RESERVED" 1
check "the other 11 replayed or were refused" "$((REPLAY + DENIED))" 11
check "counter is exactly 1" "$(used "$U")" 1
check "one ledger row for the key" \
  "$(q "SELECT count(*) FROM ai_requests
        WHERE user_id='$U' AND client_request_id='same-key';")" 1

echo
echo '# a crowd at the cap boundary cannot overshoot it'
U=$(mkuser 'conc-cap@test.local')
q "INSERT INTO ai_usage_counters (user_id, period, pool, used)
   SELECT '$U', ai_current_period(timezone), 'requests', $CAP - 1
   FROM profiles WHERE id='$U';" >/dev/null
race 12 "$U" succeeded
check "exactly one of 12 got the last unit" "$RESERVED" 1
check "the other 11 were refused" "$DENIED" 11
check "counter stopped at the cap" "$(used "$U")" "$CAP"

echo
echo '# a crowd sharing one credit spends only that credit'
U=$(mkuser 'conc-credit@test.local')
q "INSERT INTO subscriptions (user_id, tier, expires_at, will_renew)
   VALUES ('$U','premium'::subscription_tier, now() + interval '30 days', true)
   ON CONFLICT (user_id) DO UPDATE
     SET tier = 'premium'::subscription_tier, expires_at = EXCLUDED.expires_at;
   UPDATE profiles SET ai_cooldown_until = now() + interval '1 hour',
                       ai_credit_balance = 1 WHERE id='$U';" >/dev/null
race 12 "$U" succeeded
check "exactly one of 12 spent the credit" "$RESERVED" 1
check "balance is zero, never negative" \
  "$(q "SELECT ai_credit_balance FROM profiles WHERE id='$U';")" 0

echo
echo "all $pass concurrency checks passed"
