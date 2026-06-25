# S16 Smoke Verification — Recall Drop notifications

**Sprint:** S16 Recall Drop notifications
**Environment:** `recall-staging` (`vxbqzzebiuxzywmekdex`)
**Date:** 2026-06-26
**Status:** Backend deployed & smoke-verified on staging. On-device QA (real push
→ delivered/opened + deep-link) pending a device build.

## Results

| Check | Result |
| --- | --- |
| `00014_compute_due_rpc` applied | yes |
| Vault `app_cron_secret` created (matches EF `CRON_SECRET`) | yes |
| `00015_compute_due_cron` applied | yes |
| `cron.job` `compute-due-15min` `*/15 * * * *` | active |
| `compute-due` EF deployed (`verify_jwt=false`) | ACTIVE v1 |
| POST no `X-Cron-Secret` | 401 |
| POST wrong secret | 401 |
| POST correct secret | 200 `{"users_evaluated":0,"notifications_sent":0}` |
| `select * from compute_due_candidates()` | runs clean; 0 rows (lone opted-in user under due-threshold) |
| On-device: receipt → `delivered`, tap → `opened` + lands on /today | PENDING device QA |

## Migrations to apply (staging)

- `00014_compute_due_rpc.sql` — `is_in_quiet_hours()` + service-role
  `compute_due_candidates()` (the full Drop trigger: scope, due-pool/overdue-P5,
  quiet hours, frequency budget `[D-ENG-9]`, dedupe `[D-EF-9]`, tokens).
- `00015_compute_due_cron.sql` — `invoke_compute_due()` (Vault-backed) +
  `cron.schedule('compute-due-15min', '*/15 * * * *', ...)`.

## Edge Function to deploy

- `compute-due` (`verify_jwt = false`; authenticates via `X-Cron-Secret`).
  Depends on `_shared/{cors,errors,supabase,fcm}.ts`.

## Pre-deploy: Vault secrets (staging SQL, once)

`00015` reads these from Supabase Vault. `app_supabase_url` already exists from
S06; add `app_cron_secret` = the staging `CRON_SECRET` (`secrets/cron-staging.txt`,
already set as the `compute-due` EF env secret so the two match):

```sql
select vault.create_secret(
  '<contents of secrets/cron-staging.txt>',
  'app_cron_secret',
  'S16 cron → compute-due X-Cron-Secret'
);
-- verify app_supabase_url is present (added in S06); if missing, create it too:
-- select vault.create_secret('https://vxbqzzebiuxzywmekdex.supabase.co','app_supabase_url','');
```

## Deploy steps

Via Supabase MCP (once authenticated):
1. `apply_migration` `compute_due_rpc` ← `00014_compute_due_rpc.sql`
2. Run the Vault SQL above (`execute_sql`)
3. `apply_migration` `compute_due_cron` ← `00015_compute_due_cron.sql`
4. `deploy_edge_function` `compute-due` (`verify_jwt: false`, files: `index.ts`
   + `../_shared/{cors,errors,supabase,fcm}.ts`)

Or via CLI (linked staging): `supabase db push` then
`supabase functions deploy compute-due`.

## Smoke checks

| Check | Expected |
| --- | --- |
| `POST /functions/v1/compute-due` no `X-Cron-Secret` | `401 unauthorized`, no logic runs |
| `POST /functions/v1/compute-due` with correct secret | `200 { users_evaluated, notifications_sent }` |
| `select * from cron.job where jobname='compute-due-15min'` | one row, `*/15 * * * *` |
| User below threshold (`due_pool < 5`, no overdue P5) | not in `compute_due_candidates()` |
| User at/over threshold, out of cooldown, has token | a `sent` row with `dedupe_key={uid}:{local_date}` |
| Second tick same local day | no duplicate `sent` (`(dedupe_key,type)` UNIQUE) |
| In quiet hours (tz wrap-around) | excluded |
| Frequency budget spent (rolling 7d) | excluded |
| Downgraded user (`free` + `had_premium`) | only first 3 buckets in scope `[Block B5]` |
| On-device receipt (foreground) | `delivered` row logged + `drop_received` breadcrumb |
| Notification tap (bg/terminated) | `opened` row logged, lands on `/today`, `drop_opened` breadcrumb |
| Stale token (FCM `UNREGISTERED`) | row pruned from `device_tokens`, no `sent` if it was the only token |

## Manual fixture (force a candidate)

```sql
-- pick a test user with push_opt_in=true + a device_tokens row, then ensure due pool:
update profiles set push_opt_in = true, quiet_hours_start = null, quiet_hours_end = null
where id = '<uid>';
-- make ≥5 nodes due now in an out-of-cooldown active bucket, then invoke compute-due.
```

## Notes

- All Drop-trigger logic is server-side (SQL); the EF only does FCM I/O + logging
  and the app only registers tokens, logs receipt/open, and deep-links.
- `sent` is logged **after** a successful FCM send so a permanent failure never
  claims the dedupe key (would suppress a real future Drop).
- Prod (`FCM_SERVICE_ACCOUNT_JSON`, Vault secrets, cron) deferred to S27.
