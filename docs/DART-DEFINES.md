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

**Project ref:** `vxbqzzebiuxzywmekdex`  
**Publishable key:** stored in `secrets/LOCAL-SECRETS.md` (maps to `SUPABASE_ANON_KEY` dart-define).

```bash
flutter run \
  --dart-define=ENV=staging \
  --dart-define=SUPABASE_URL=https://vxbqzzebiuxzywmekdex.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<from secrets/LOCAL-SECRETS.md> \
  --dart-define=SENTRY_DSN=https://7ebc34d33823d5e5f6f34f5f795331d2@o4511616964558848.ingest.us.sentry.io/4511616969998336 \
  --dart-define=REVENUECAT_API_KEY=<rc-staging-sdk-key>
```

## Production example

**Project ref:** `cpyhkjourabizancgkjm`  
**Publishable key:** stored in `secrets/LOCAL-SECRETS.md`.

Preferred (gitignored file — never commit):

```bash
cp config/prod.example.json config/prod.json   # fill from secrets/LOCAL-SECRETS.md
fvm flutter run --flavor prod --dart-define-from-file=config/prod.json
```

Or inline:

```bash
flutter run \
  --dart-define=ENV=prod \
  --dart-define=SUPABASE_URL=https://cpyhkjourabizancgkjm.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<from secrets/LOCAL-SECRETS.md> \
  --dart-define=SENTRY_DSN=<prod-sentry-dsn-or-empty> \
  --dart-define=REVENUECAT_API_KEY=<rc-prod-sdk-key-or-empty>
```

First IAP wave uses **RC staging** (`app.recall.staging`); leave prod `REVENUECAT_API_KEY` empty until RC prod is wired (see [`S23-SMOKE.md`](S23-SMOKE.md)).

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
