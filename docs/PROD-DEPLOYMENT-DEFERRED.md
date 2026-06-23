# Prod deployment — deferred to S27

**Owner:** S27 final QA + ship · **Not blocking** S01–S26 on staging.

Staging infra is complete ([`PREFLIGHT-CHECKLIST.md`](PREFLIGHT-CHECKLIST.md)). Prod Supabase (`cpyhkjourabizancgkjm`) is **partially** provisioned (project, link, extensions, auth URLs, `CRON_SECRET`, Gemini/Anthropic). Complete the mirror below before prod release.

Cross-reference: [`Roadmap/sprints/S27-final-qa.md`](../../Roadmap/sprints/S27-final-qa.md) · [`MIGRATION-WORKFLOW.md`](MIGRATION-WORKFLOW.md)

---

## Already done (prod partial)

- [x] Supabase project `recall-prod` — ref `cpyhkjourabizancgkjm`
- [x] CLI linked; extensions `pg_cron`, `pg_net`, `vector`, `pgcrypto`
- [x] Auth site URL + redirect (`app.recall://login-callback`); email OTP
- [x] `CRON_SECRET`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY` on prod Supabase
- [x] Firebase `recall-spaced-prod`; Android/iOS apps; `google-services.prod.json` in vault
- [x] Publishable + secret API keys in `secrets/LOCAL-SECRETS.md`

---

## Pending before prod ship

### Sentry `[D-OBS-1]`

- [ ] Create Flutter project `recall-prod`
- [ ] Capture prod DSN → `secrets/LOCAL-SECRETS.md` + prod dart-define

### Supabase Auth (prod)

- [ ] Google provider: Web client ID + secret in Supabase Auth
- [ ] GCP Android OAuth client: package `app.recall` + **release** SHA-1 (debug SHA-1 insufficient for Play)
- [ ] iOS Google OAuth client: bundle `app.recall` (when testing iOS prod)
- [ ] Apple Sign-In + redirect (if Apple Developer enrolled)

### Edge Function secrets (prod Supabase)

Set via `./scripts/link-prod.sh` then `supabase secrets set` or dashboard:

- [ ] `REVENUECAT_WEBHOOK_SECRET`
- [ ] `REVENUECAT_REST_API_KEY`
- [ ] `FCM_SERVICE_ACCOUNT_JSON` (from `recall-spaced-prod` service account)

### RevenueCat (prod)

- [ ] Prod app (`app.recall`) linked to Play / App Store
- [ ] Entitlement `premium`, offering `default`, same 4 SKUs `[D-PAY-1]`
- [ ] Webhook URL: `https://cpyhkjourabizancgkjm.supabase.co/functions/v1/revenuecat-webhook`
- [ ] Public SDK keys: `goog_...` / `appl_...` for prod dart-define

### Firebase / FCM

- [ ] Prod FCM service account JSON → Supabase secret
- [ ] APNs auth key uploaded (Apple Developer required)
- [ ] Optional cleanup: delete duplicate `app.recall` apps from `recall-spaced-staging`

### Database

- [ ] All migrations applied staging → smoke test → prod (`supabase db push`)
- [ ] Final schema parity verified (S27 gate)

### Flutter prod build

- [ ] Prod `--dart-define` set: `ENV=prod`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SENTRY_DSN`, `REVENUECAT_API_KEY`
- [ ] Sentry test event on prod flavor

---

## Verification (S27)

Tick this section complete when [`STATUS.md`](../../Roadmap/sprints/STATUS.md) cross-cutting item **Prod infra mirror complete** is checked.
