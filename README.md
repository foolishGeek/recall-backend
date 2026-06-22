# recall-backend

Supabase backend for **Recall**.

## Setup (Prompt 2)

- Supabase CLI linked to `recall-staging` and `recall-prod`
- Migrations applied staging first, then prod

## Structure

```
supabase/
  migrations/     # Postgres schema, RLS, views
  functions/      # Edge Functions (ai-forge, compute-due, …)
```

Canonical schema: [`../Roadmap/02-data-layer.md`](../Roadmap/02-data-layer.md)

## Latency

- CRUD paths: ~100ms avg, p95 &lt; 300ms
- AI/embed/quiz functions: excluded (async)

## Git

Separate repository. Commit meaningful chunks after user approval. Do not push unless asked.

## Docs

- [Engine spec](../Roadmap/00-engine-design.md)
- [PRD traceability](../Roadmap/PRD-traceability.md)
