# S00 Pre-flight checklist

**Sprint:** Infra & provisioning · **Owner:** `recall-backend` / ops  
**Last updated:** S00 execution

Legend: `[x]` done · `[~]` partial · `[ ]` pending · `BLOCKED` needs external account

---

## Pinned identifiers

| Key | Staging | Production |
|-----|---------|------------|
| Flutter flavor | `staging` | `prod` |
| Bundle / applicationId | `app.recall.staging` | `app.recall` |
| Auth Site URL + redirect | `app.recall.staging://login-callback` | `app.recall://login-callback` |
| Staging extra redirect | `http://localhost:**` | — |

See [`secrets/IDENTIFIERS.md`](../secrets/IDENTIFIERS.md) (local, gitignored) for refs and generated `CRON_SECRET` values.

---

## Supabase projects

- [ ] Create `recall-staging` at [dashboard.supabase.com](https://supabase.com/dashboard)
- [ ] Create `recall-prod` (same region as staging)
- [x] `recall-backend/`: `supabase init` completed
- [ ] `supabase link --project-ref <staging-ref>` — **requires `npx supabase login`**
- [x] Migration workflow documented → [`MIGRATION-WORKFLOW.md`](MIGRATION-WORKFLOW.md)

**Helper:** `./scripts/provision-supabase.sh` after CLI login.

---

## Auth dashboard (each project)

| Item | Staging | Prod |
|------|---------|------|
| Email OTP | [ ] | [ ] |
| Google | [ ] | [ ] |
| Apple | BLOCKED — no Apple Developer | BLOCKED |
| Site URL | `app.recall.staging://login-callback` | `app.recall://login-callback` |
| Redirect URLs | scheme + `http://localhost:**` | scheme only |

**Google OAuth:** Google Cloud Console → OAuth consent + Web client → paste into Supabase Auth → Google. Android clients need package + debug SHA-1:

```
86:78:B0:8D:02:05:56:79:CC:5B:AE:67:C4:E2:35:4D:9B:07:EE:B9
```

Release SHA-1: add before prod ship (S27).

---

## Edge Function secrets (per project)

Set via dashboard or `./scripts/set-ef-secrets.sh` (linked project + filled `.env`).

| Secret | Staging | Prod | Notes |
|--------|---------|------|-------|
| `GEMINI_API_KEY` | [ ] | [ ] | User-supplied |
| `ANTHROPIC_API_KEY` | [ ] | [ ] | User-supplied |
| `OPENAI_API_KEY` | [ ] | [ ] | User-supplied |
| `REVENUECAT_WEBHOOK_SECRET` | [ ] | [ ] | From RC webhook |
| `REVENUECAT_REST_API_KEY` | [ ] | [ ] | `[D-EF-7]` |
| `FCM_SERVICE_ACCOUNT_JSON` | [ ] | [ ] | Firebase service account |
| `CRON_SECRET` | [x] generated | [x] generated | `secrets/cron-*.txt` |
| `SUPABASE_SERVICE_ROLE_KEY` | auto | auto | Do not set manually |

---

## Firebase / FCM

| Item | Staging | Prod |
|------|---------|------|
| GCP / Firebase project | [x] `recall-spaced-staging` | [x] `recall-spaced-prod` |
| Android app registered | [x] `app.recall.staging` | [x] `app.recall` |
| iOS app registered | [x] bundle `app.recall.staging` | [x] bundle `app.recall` |
| Debug SHA-1 on Android app | [x] | [x] |
| `google-services.json` | [x] `secrets/firebase/` | [x] `secrets/firebase/` |
| FCM service account → secret | [ ] | [ ] | IAM → Firebase Admin SDK |
| APNs key in Firebase | BLOCKED | BLOCKED | Apple Developer required |

**Cleanup:** `recall-spaced-staging` has duplicate prod bundle apps from an MCP mis-route — safe to delete `Recall Prod Android` / `Recall Prod iOS` there; canonical prod apps live in `recall-spaced-prod`.

**Note:** GCP IDs `recall-staging` / `recall-prod` were globally taken; Firebase uses `recall-spaced-*` (display names still "Recall Staging/Prod").

---

## Extensions / cron

Run [`scripts/sql/enable-extensions.sql`](../scripts/sql/enable-extensions.sql) in SQL Editor **per project**:

- [ ] `pg_cron`
- [ ] `pg_net` — if unavailable, note fallback: Supabase scheduled Edge Function for `compute-due` (S16)
- [ ] `vector`
- [ ] `pgcrypto`

Do **not** schedule cron jobs in S00 (S16).

---

## RevenueCat (staging required)

Per `[D-PAY-1]`:

| Item | Status |
|------|--------|
| Staging app | [ ] |
| Entitlement `premium` | [ ] |
| Offering `default` | [ ] |
| Product `recall_premium_monthly` | [ ] |
| Product `recall_premium_yearly` | [ ] |
| Product `ai_credits_100` | [ ] |
| Product `ai_credits_500` | [ ] |
| Webhook URL reserved | [ ] `https://<staging-ref>.supabase.co/functions/v1/revenuecat-webhook` |

Prod RC app: optional in S00; dart-defines doc includes prod key slot.

---

## Sentry `[D-OBS-1]`

| Item | Status |
|------|--------|
| Project `recall-staging` (Flutter) | [ ] |
| Project `recall-prod` (Flutter) | [ ] |
| DSNs captured locally | [ ] → `secrets/LOCAL-SECRETS.template.md` |

Init in app: S02.

---

## Flutter dart-defines

Documented in [`DART-DEFINES.md`](DART-DEFINES.md). Consumed from S02.

---

## Definition of Done (S00)

- [ ] Staging project reachable; CLI linked
- [ ] Auth providers + redirect URLs configured
- [ ] All secrets set (incl. `REVENUECAT_REST_API_KEY`); extensions enabled
- [ ] RevenueCat staging app + 4 products + webhook URL reserved
- [ ] Sentry staging + prod DSNs captured
- [x] Pre-flight checklist committed to `recall-backend`
- [x] No schema migrations, Edge Functions, or Flutter code in this sprint

**Automated in S00:** Firebase projects/apps, `supabase init`, scripts, CRON secrets generated, Android `google-services.json` in local vault.

**Requires your action:** Supabase login + project create, Sentry/RevenueCat portals, AI API keys, FCM service account JSON, Google OAuth Web client → Supabase, extension SQL on remote DBs.
