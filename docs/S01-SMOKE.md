# S01 Smoke Verification

**Sprint:** S01 DB schema, migrations, views  
**Environment:** `recall-staging` (`vxbqzzebiuxzywmekdex`)  
**Date:** 2026-06-24

## Applied Migrations

- `00001_initial.sql`
- `00002_harden_rls.sql`

`00002_harden_rls.sql` was added after the staging advisor pass to remove default public execution from helper functions and optimize RLS auth calls.

## Results

| Check | Result |
| --- | --- |
| Tables | 27 |
| Views | 9 |
| Enums | 13 |
| RLS-enabled public tables | 27 |
| Security-invoker views | 9 |
| `app_config` keys | 24 |
| Achievements | 12 |
| Global `scheduling_params` row | 1 |
| Private storage buckets | 2 (`node-pdfs`, `node-images`) |
| Two-user RLS isolation | Passed |
| Security-invoker view isolation | Passed |
| `match_chunks` owner filtering | Passed |
| Storage `{user_id}/` prefix policies | Passed |
| Free-tier third bucket error | Passed: `P0001/free_tier_bucket_limit` |
| Supabase security advisors | No issues found |
| Supabase performance advisors | No issues found |

## Notes

- Local `supabase db reset` was not run because Docker Desktop was unavailable.
- Remote staging migration and smoke checks were run through `npx supabase@latest`.
- Supabase emitted a post-push migration-catalog cache warning because Docker was unavailable; the remote migrations completed successfully.
