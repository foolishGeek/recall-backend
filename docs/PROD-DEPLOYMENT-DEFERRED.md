# Prod deployment — status

**Owner:** S27 final QA + ship · Cross-reference: [`MIGRATION-WORKFLOW.md`](MIGRATION-WORKFLOW.md) · [`S23-SMOKE.md`](S23-SMOKE.md)

Staging infra remains the daily driver. Recall-prod (`cpyhkjourabizancgkjm`) cutover applied 2026-07-19.

---

## Done on prod

- [x] Supabase project `recall-prod` — ref `cpyhkjourabizancgkjm`
- [x] CLI linked; extensions `pg_cron`, `pg_net`, `vector`, `pgcrypto`
- [x] Auth site URL + redirect (`app.recall://login-callback`); email OTP
- [x] Send Email Auth Hook → `auth-send-email` (SMTP2GO, same mailbox as staging)
- [x] Brand assets in public `brand-assets` Storage bucket
- [x] Migrations `00001`–`00061` applied (engine-ux-overhaul through the AI entitlement policy table, request ledger and durable embed queue; auto-tune & per-user weights ship behind default-off kill-switches)
- [x] AI caps now come from `ai_feature_policy` / `v_ai_policy`, keyed on `app_config.limits_profile` (live value: `relaxed` → 500 requests / 50 overviews)
- [x] Vault: `app_supabase_url`, `app_service_role_key`, `app_cron_secret`
- [x] Cron jobs: `compute-due-5min`, `cleanup-exports-hourly`, `onboarding-emails-2min`, `prune-device-tokens-daily`, `embed-drain-every-minute`
- [x] All 16 Edge Functions deployed (adds `embed-drain`, `verify_jwt = false`, cron-secret authenticated)
- [x] EF secrets: AI keys, `CRON_SECRET`, SMTP2GO, Zoho, FCM (prod SA), Send Email hook, RC webhook placeholder
- [x] Firebase `recall-spaced-prod`; `google-services.prod.json` + `fcm-service-account.prod.json` in vault
- [x] Flutter `config/prod.example.json` + local `config/prod.json` (gitignored)

---

## Still pending (not blocking core e2e)

### Supabase Auth (prod)

- [ ] Google provider: Web client ID + secret in Supabase Auth
- [ ] GCP Android OAuth client: package `app.recall` + **release** SHA-1
- [ ] iOS Google OAuth client: bundle `app.recall` (when testing iOS prod)
- [ ] Apple Sign-In + redirect (if Apple Developer enrolled)

### RevenueCat (prod) — after first IAP wave on RC staging

- [ ] Prod app (`app.recall`) linked to Play / App Store
- [ ] Entitlement `premium`, offering `default`, same 4 product ids `[D-PAY-1]`
  - Play store ids: `recall_premium_monthly:<basePlan>`, `recall_premium_yearly:<basePlan>` (prefer reuse `recall-01` / `recall-02`; if different, update mobile `playMonthlyStoreId` / `playYearlyStoreId` or rely on `matchesProductId` prefix match)
  - Consumables: `ai_credits_100`, `ai_credits_500` (no `premium` entitlement)
- [ ] Webhook URL: `https://cpyhkjourabizancgkjm.supabase.co/functions/v1/revenuecat-webhook`
- [ ] Real `REVENUECAT_REST_API_KEY` + webhook secret dedicated to prod RC (replace placeholder)
- [ ] Public SDK keys for prod dart-define (`config/prod.json` `REVENUECAT_API_KEY`)
- [ ] Money gate: one Closed/Internal sandbox purchase → `subscriptions` flip on Recall-prod → refund/expire path
- [ ] Do not promote public Production track until Wave A smoke A–G + money gate pass ([`S23-SMOKE.md`](S23-SMOKE.md))

### Firebase / FCM

- [x] Prod FCM service account JSON → Supabase secret
- [ ] APNs auth key uploaded (Apple Developer required)

### Flutter

- [x] Prod `--dart-define-from-file=config/prod.json`
