# S00 portal setup runbook

Step-by-step for items that require browser login. Run after reading [`PREFLIGHT-CHECKLIST.md`](PREFLIGHT-CHECKLIST.md).

---

## 1. Supabase

1. Sign up / log in at [supabase.com/dashboard](https://supabase.com/dashboard).
2. Create organization (if needed).
3. **New project** → name `recall-staging` → choose region → set DB password (store in password manager).
4. Repeat for `recall-prod` (same region).
5. CLI:

```bash
cd recall-backend
npx supabase login
./scripts/provision-supabase.sh
```

6. Per project → **SQL Editor** → run [`scripts/sql/enable-extensions.sql`](../scripts/sql/enable-extensions.sql).

---

## 2. Supabase Auth

**Staging** (`recall-staging`):

- Authentication → Providers → Email: enable, confirm email optional for magic link.
- Google: enable after OAuth client ready (step 4).
- Apple: leave disabled (`BLOCKED`).
- URL Configuration:
  - Site URL: `app.recall.staging://login-callback`
  - Redirect URLs: `app.recall.staging://login-callback`, `http://localhost:**`

**Production** (`recall-prod`):

- Same providers except no `localhost` redirect.
- Site URL + redirect: `app.recall://login-callback`

---

## 3. Google Cloud OAuth (Sign in with Google)

1. [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → OAuth consent screen → External → app name **Recall**.
2. **Credentials** → Create **OAuth client ID**:
   - **Web application** — for Supabase. Authorized redirect URI = Supabase Auth callback (shown in Supabase → Auth → Google).
   - **Android** — package `app.recall.staging`, SHA-1 debug fingerprint (see checklist).
   - **Android** — package `app.recall`, same SHA-1 for now.
   - **iOS** — bundle `app.recall.staging` / `app.recall` (usable when Apple Developer exists).
3. Paste Web client ID + secret into **both** Supabase projects → Auth → Google.

---

## 4. FCM service account

Per Firebase project (`recall-spaced-staging`, `recall-spaced-prod`):

1. Firebase Console → Project settings → Service accounts.
2. **Generate new private key** (JSON).
3. Minify to one line or pass as JSON string → Supabase secret `FCM_SERVICE_ACCOUNT_JSON` on the matching Supabase project (staging Firebase ↔ staging Supabase).

---

## 5. RevenueCat (staging)

1. [app.revenuecat.com](https://app.revenuecat.com) → New project.
2. Add app (iOS + Android) with bundle IDs `app.recall.staging`.
3. **Entitlements** → `premium`.
4. **Products** → create identifiers: `recall_premium_monthly`, `recall_premium_yearly`, `ai_credits_100`, `ai_credits_500`.
5. **Offerings** → `default` → attach monthly + yearly packages.
6. **Integrations** → Webhooks → URL:

   `https://<staging-ref>.supabase.co/functions/v1/revenuecat-webhook`

   Copy authorization secret → `REVENUECAT_WEBHOOK_SECRET`.
7. **API keys** → REST API key → `REVENUECAT_REST_API_KEY`; Public SDK key → dart-define `REVENUECAT_API_KEY`.

Store products in sandbox until App Store / Play listings exist (S23).

---

## 6. Sentry

1. [sentry.io](https://sentry.io) → Create organization.
2. **Create project** → platform **Flutter** → name `recall-staging`.
3. Copy DSN.
4. Repeat for `recall-prod`.
5. Save DSNs in local secrets vault (see `secrets/LOCAL-SECRETS.template.md`).

---

## 7. Set Edge Function secrets

```bash
cp .env.example .env
# fill all keys
./scripts/set-ef-secrets.sh
# re-link and repeat for prod project
```

`CRON_SECRET` values are pre-generated in `secrets/cron-staging.txt` and `secrets/cron-prod.txt`.

---

## 8. Verify

Tick items in [`PREFLIGHT-CHECKLIST.md`](PREFLIGHT-CHECKLIST.md).
