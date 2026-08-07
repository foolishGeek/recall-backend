# Flutter `--dart-define` inventory

Consumed from **S02** (`RecallApp` bootstrap / `SupabaseService`). Values live in your local secrets vault only — **never commit**.

Canon: [`CANON-DECISIONS.md`](../../Roadmap/sprints/CANON-DECISIONS.md) §Environments.

---

## Keys (both flavors)

| Key | Purpose |
|-----|---------|
| `ENV` | `staging` or `prod` — flavor gates |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | Supabase publishable anon key |
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
  --dart-define=REVENUECAT_API_KEY=<rc-prod-sdk-key-or-empty>
```

First IAP wave uses **RC staging** (`app.recall.staging`); leave prod `REVENUECAT_API_KEY` empty until RC prod is wired (see [`S23-SMOKE.md`](S23-SMOKE.md)).

---

## Where values come from

| Key | Source |
|-----|--------|
| `SUPABASE_*` | Supabase project → Settings → API (after `recall-staging` / `recall-prod` created) |
| `REVENUECAT_API_KEY` | RevenueCat → Project → API keys → Public app-specific key |

Store filled values in `secrets/LOCAL-SECRETS.md` (copy from `LOCAL-SECRETS.template.md`).
