# Flutter `--dart-define` inventory

Consumed from **S02** (`RecallApp` bootstrap / `SupabaseService`). Values live in your local secrets vault only — **never commit**.

Canon: [`CANON-DECISIONS.md`](../../Roadmap/sprints/CANON-DECISIONS.md) §Environments.

---

## Keys (both flavors)

| Key | Purpose |
|-----|---------|
| `ENV` | `staging` or `prod` — Sentry environment + flavor gates |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | Supabase publishable anon key |
| `SENTRY_DSN` | Crash reporting `[D-OBS-1]` |
| `REVENUECAT_API_KEY` | RevenueCat public SDK key (not REST, not webhook secret) |

---

## Staging example

```bash
flutter run \
  --dart-define=ENV=staging \
  --dart-define=SUPABASE_URL=https://<staging-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<staging-anon-key> \
  --dart-define=SENTRY_DSN=<staging-sentry-dsn> \
  --dart-define=REVENUECAT_API_KEY=<rc-staging-sdk-key>
```

## Production example

```bash
flutter run \
  --dart-define=ENV=prod \
  --dart-define=SUPABASE_URL=https://<prod-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<prod-anon-key> \
  --dart-define=SENTRY_DSN=<prod-sentry-dsn> \
  --dart-define=REVENUECAT_API_KEY=<rc-prod-sdk-key>
```

---

## Where values come from

| Key | Source |
|-----|--------|
| `SUPABASE_*` | Supabase project → Settings → API (after `recall-staging` / `recall-prod` created) |
| `SENTRY_DSN` | Sentry project → Client Keys (DSN) |
| `REVENUECAT_API_KEY` | RevenueCat → Project → API keys → Public app-specific key |

Store filled values in `secrets/LOCAL-SECRETS.md` (copy from `LOCAL-SECRETS.template.md`).

---

## Sentry sampling (set in S02 code, not dart-define)

- Staging: `tracesSampleRate = 0.2`
- Prod: `tracesSampleRate = 0.05`

Empty `SENTRY_DSN` → skip Sentry init (local dev).
