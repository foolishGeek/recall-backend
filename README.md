# recall-backend

Supabase backend for **Recall**.

## S00 — Infra (current)

| Doc | Purpose |
|-----|---------|
| [`docs/PREFLIGHT-CHECKLIST.md`](docs/PREFLIGHT-CHECKLIST.md) | Sprint DoD tracker |
| [`docs/SETUP-RUNBOOK.md`](docs/SETUP-RUNBOOK.md) | Portal steps (Supabase, OAuth, RC, Sentry) |
| [`docs/DART-DEFINES.md`](docs/DART-DEFINES.md) | Flutter `--dart-define` keys per flavor |
| [`docs/MIGRATION-WORKFLOW.md`](docs/MIGRATION-WORKFLOW.md) | staging → smoke → prod |
| [`docs/PROD-DEPLOYMENT-DEFERRED.md`](docs/PROD-DEPLOYMENT-DEFERRED.md) | Prod mirror checklist (S27) |

**CLI:** use `npx supabase@latest` (Homebrew install may require newer Xcode).

```bash
npx supabase login
./scripts/provision-supabase.sh
```

Local secrets vault: `secrets/` (gitignored). Firebase GCP IDs: `recall-spaced-staging`, `recall-spaced-prod`.

## Setup (S01+)

- Supabase CLI linked to `recall-staging` (daily) and `recall-prod` (releases)
- Migrations applied staging first, then prod

## Structure

```
supabase/
  migrations/     # Postgres schema, RLS, views (S01+)
  functions/      # Edge Functions (S06+)
scripts/          # S00 provisioning helpers
docs/             # Checklists and runbooks
```

Canonical schema: [`S01`](../Roadmap/sprints/S01-schema-migrations.md) · API contracts: per-feature sprints · [`COVERAGE-LEDGER.md`](../Roadmap/sprints/COVERAGE-LEDGER.md)

## Latency

- CRUD paths: ~100ms avg, p95 &lt; 300ms
- AI/embed/quiz functions: excluded (async)

## Git

Separate repository. Commit meaningful chunks after user approval. Do not push unless asked.

## Docs

- [Engine spec](../Roadmap/sprints/S04-engine.md)
- [Canon decisions](../Roadmap/sprints/CANON-DECISIONS.md) · [Coverage ledger](../Roadmap/sprints/COVERAGE-LEDGER.md)
