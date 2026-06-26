# S26 Smoke Verification — Downgraded-tier pass

**Sprint:** S26 Downgraded-tier pass  
**Environment:** `recall-staging` (`vxbqzzebiuxzywmekdex`)  
**Migration:** `00029_downgraded_tier_guards.sql`

## Demo user setup

Pick a staging user with **4+ buckets** (created while premium) so buckets 4+ are read-only after downgrade.

```sql
-- Replace with your test user's UUID
\set demo_user '00000000-0000-0000-0000-000000000001'

UPDATE subscriptions
SET tier = 'free', will_renew = false, expires_at = NULL
WHERE user_id = :'demo_user';

UPDATE profiles
SET had_premium = true
WHERE id = :'demo_user';
```

Obtain a JWT for the demo user (Supabase dashboard → Authentication → user → impersonate, or sign in on device and copy from logs).

```bash
export SUPABASE_URL="https://vxbqzzebiuxzywmekdex.supabase.co"
export ANON_KEY="<publishable-anon-key>"
export DEMO_JWT="<demo-user-access-token>"
```

## Results matrix

| Check | Command / path | Expected |
| --- | --- | --- |
| Active buckets | `rpc active_buckets_for_user` | 3 rows (oldest by `created_at`) |
| Bucket INSERT #4+ | `INSERT INTO buckets …` | `P0001` / `free_tier_bucket_limit` |
| Bucket #4 config UPDATE | `UPDATE buckets SET name=…` | `free_tier_bucket_limit` |
| Node in bucket #4 INSERT/UPDATE | `INSERT/UPDATE nodes` | `free_tier_bucket_limit` |
| Node in bucket #3 | write | allowed |
| `ai-forge` rag_chat | POST | 403 `premium_required` |
| `ai-forge` evaluate | POST | 403 `premium_required` |
| `ai-forge` summarize | POST | 403 `premium_required` |
| `quiz-generate` | POST | 403 `premium_required` |
| `retention-simulate` | POST | 403 `premium_required` |
| `generate_stack_rpc()` | RPC (null scope) | items only from first 3 buckets |
| `today_summary_rpc()` | RPC | due count excludes bucket 4+ nodes |
| Re-upgrade | webhook `RENEWAL` | `tier=premium`; all buckets writable; AI allowed |

## curl examples

```bash
# Active buckets
curl -s "$SUPABASE_URL/rest/v1/rpc/active_buckets_for_user" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $DEMO_JWT" \
  -H "Content-Type: application/json" \
  -d '{"uid":"<demo-user-uuid>"}' | jq 'length'   # expect 3

# AI chat (downgraded)
curl -s "$SUPABASE_URL/functions/v1/ai-forge" \
  -H "Authorization: Bearer $DEMO_JWT" \
  -H "Content-Type: application/json" \
  -d '{"feature":"rag_chat","payload":{"question":"test"}}' | jq '.error'   # premium_required

# Retention simulate
curl -s -X POST "$SUPABASE_URL/functions/v1/retention-simulate" \
  -H "Authorization: Bearer $DEMO_JWT" \
  -H "Content-Type: application/json" \
  -d '{}' | jq '.error'   # premium_required

# Quiz generate (needs valid config_id owned by user)
curl -s -X POST "$SUPABASE_URL/functions/v1/quiz-generate" \
  -H "Authorization: Bearer $DEMO_JWT" \
  -H "Content-Type: application/json" \
  -d '{"config_id":"<uuid>"}' | jq '.error'   # premium_required
```

## Re-upgrade smoke

Simulate RevenueCat `RENEWAL` via `apply_revenuecat_event` (service role) or sandbox purchase → webhook:

```sql
SELECT apply_revenuecat_event('{
  "id": "smoke-renewal-s26",
  "type": "RENEWAL",
  "app_user_id": "<demo-user-uuid>",
  "product_id": "recall_premium_monthly"
}'::jsonb);
```

Then verify `subscriptions.tier = premium` and `active_buckets_for_user` returns all buckets.

## Mobile manual matrix

After migration + mobile build:

1. Sign in as demo user → Buckets: first 3 normal, 4+ sunken/read-only, FAB locked.
2. Open bucket #4 → config disabled, no AI chips, no FAB.
3. AI Chat → locked composer "resubscribe to continue".
4. Quiz tab → PRO lock; direct API still 403.
5. Insights → locked premium teasers (= free).
6. Settings → EXPIRED card, frozen credits.
7. Visit Quiz tab → tier stays downgraded (no reset to free).
8. Light + dark pixel pass per `Design/handover/`.

## Notes

- Apply `00029` to staging before smoke: `supabase db push` or Supabase MCP `apply_migration`.
- Credit spend while downgraded: `ai_gate_consume` returns `premium_required` before balance deduction.
- Frozen credits are not refunded on downgrade (v1 policy).
