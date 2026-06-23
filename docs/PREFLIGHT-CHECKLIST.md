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

| | Staging | Production |
|--|---------|------------|
| Name | `recall-staging` | `recall-prod` |
| Project ref | `vxbqzzebiuxzywmekdex` | `cpyhkjourabizancgkjm` |
| URL | `https://vxbqzzebiuxzywmekdex.supabase.co` | `https://cpyhkjourabizancgkjm.supabase.co` |
| Region | `ap-southeast-1` | `ap-northeast-2` |
| Publishable key | in `LOCAL-SECRETS.md` | in `LOCAL-SECRETS.md` |

- [x] Create `recall-staging` — ref `vxbqzzebiuxzywmekdex` (region `ap-southeast-1`)
- [x] Create `recall-prod` — ref `cpyhkjourabizancgkjm` (region `ap-northeast-2`)
- [x] `recall-backend/`: `supabase init` completed
- [x] Staging API keys verified (publishable + secret → local vault)
- [x] `supabase link --project-ref vxbqzzebiuxzywmekdex` (staging — default CLI target)
- [x] `supabase link --project-ref cpyhkjourabizancgkjm` (prod)
- [x] Extensions enabled on prod
- [x] `CRON_SECRET` set on prod
- [x] Extensions enabled: `pg_cron`, `pg_net`, `vector`, `pgcrypto`
- [x] `CRON_SECRET` set on staging
- [x] Migration workflow documented → [`MIGRATION-WORKFLOW.md`](MIGRATION-WORKFLOW.md)

**Helper:** `./scripts/provision-supabase.sh` after CLI login.

---

## Auth dashboard (each project)

| Item | Staging | Prod |
|------|---------|------|
| Email OTP | [x] | [x] |
| Google | [x] Web in Supabase + Android client in GCP (`app.recall.staging`) | [ ] Web + Android (`app.recall`) |
| Apple | BLOCKED — no Apple Developer | BLOCKED |
| Site URL | [x] `app.recall.staging://login-callback` | [x] `app.recall://login-callback` |
| Redirect URLs | [x] scheme + `http://localhost:**` | [x] scheme only |

**Google OAuth:** Web client in Supabase Auth. **Android** OAuth client in GCP: package `app.recall.staging`, debug SHA-1 below. **iOS** OAuth client deferred (revisit before iOS testing / S08 on device).

```
86:78:B0:8D:02:05:56:79:CC:5B:AE:67:C4:E2:35:4D:9B:07:EE:B9
```

Release SHA-1: add before prod ship (S27).

---

## Edge Function secrets (per project)

Set via dashboard or `./scripts/set-ef-secrets.sh` (linked project + filled `.env`).

| Secret | Staging | Prod | Notes |
|--------|---------|------|-------|
| `GEMINI_API_KEY` | [x] | [x] | Free tier AI |
| `ANTHROPIC_API_KEY` | [x] | [x] | Premium tier AI |
| `OPENAI_API_KEY` | skip | skip | Deferred — no embeddings v1 |
| `REVENUECAT_REST_API_KEY` | [x] | [ ] | `[D-EF-7]` — `sk_` secret key |
| `REVENUECAT_WEBHOOK_SECRET` | [x] | [ ] | From RC webhook |
| `FCM_SERVICE_ACCOUNT_JSON` | [x] | [ ] | Firebase Admin SDK JSON |
| `CRON_SECRET` | [x] | [x] | `secrets/cron-*.txt` |
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
| FCM service account → secret | [x] | [ ] | IAM → Firebase Admin SDK |
| APNs key in Firebase | BLOCKED | BLOCKED | Apple Developer required |

**Cleanup:** `recall-spaced-staging` has duplicate prod bundle apps from an MCP mis-route — safe to delete `Recall Prod Android` / `Recall Prod iOS` there; canonical prod apps live in `recall-spaced-prod`.

**Note:** GCP IDs `recall-staging` / `recall-prod` were globally taken; Firebase uses `recall-spaced-*` (display names still "Recall Staging/Prod").

---

## Extensions / cron

Extensions enabled on **staging and prod** via [`scripts/sql/enable-extensions.sql`](../scripts/sql/enable-extensions.sql):

- [x] `pg_cron` (staging + prod)
- [x] `pg_net` (staging + prod)
- [x] `vector` (staging + prod)
- [x] `pgcrypto` (staging + prod)

Do **not** schedule cron jobs in S00 (S16).

---

## Prod deployment (deferred → S27)

Full checklist: [`PROD-DEPLOYMENT-DEFERRED.md`](PROD-DEPLOYMENT-DEFERRED.md). Not blocking S01–S26 on staging.

- [ ] Sentry prod DSN
- [ ] Prod Google OAuth (Web + Android `app.recall`)
- [ ] Prod RC webhook + REST secrets + public SDK keys on Supabase
- [ ] Prod `FCM_SERVICE_ACCOUNT_JSON`
- [ ] Migrations staging → prod
- [ ] Apple + APNs (if enrolled); release SHA-1; Firebase cleanup

---

## RevenueCat (staging required)

Per `[D-PAY-1]`:

| Item | Status |
|------|--------|
| Staging app | [x] Recall-Stage (Play Store) |
| Entitlement `premium` | [x] verify in RC |
| Offering `default` | [x] verify in RC |
| Product `recall_premium_monthly` | [x] |
| Product `recall_premium_yearly` | [x] |
| Product `ai_credits_100` | [x] |
| Product `ai_credits_500` | [x] |
| Webhook URL reserved | [x] `https://vxbqzzebiuxzywmekdex.supabase.co/functions/v1/revenuecat-webhook` |

Prod RC app: optional in S00; dart-defines doc includes prod key slot.

**Staging public SDK key** (`goog_...`) captured in `secrets/LOCAL-SECRETS.md` for `REVENUECAT_API_KEY` dart-define.

---

## Sentry `[D-OBS-1]`

| Item | Status |
|------|--------|
| Project `recall-staging` (Flutter) | [x] |
| Project `recall-prod` (Flutter) | [ ] deferred |
| DSNs captured locally | staging [x] prod [ ] |

Init in app: S02.

---

## Flutter dart-defines

Documented in [`DART-DEFINES.md`](DART-DEFINES.md). Consumed from S02.

---

## Definition of Done (S00)

- [x] Staging project reachable; CLI linked
- [x] Auth providers + redirect URLs configured (staging; Apple BLOCKED; iOS Google deferred)
- [x] Staging EF secrets set; extensions enabled on staging
- [x] RevenueCat staging app + 4 products + webhook URL reserved
- [x] Sentry staging DSN captured; prod DSN deferred → S27
- [x] Pre-flight checklist committed to `recall-backend`
- [x] No schema migrations, Edge Functions, or Flutter code in this sprint

**S00 closed:** staging bootstrap complete. Prod mirror → [`PROD-DEPLOYMENT-DEFERRED.md`](PROD-DEPLOYMENT-DEFERRED.md) (S27).
