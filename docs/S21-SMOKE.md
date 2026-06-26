# S21 Smoke Verification — Insights / `retention-simulate`

**Sprint:** S21 Insights (free + premium)
**Environment:** `recall-staging`
**Date:** 2026-06-26
**Status:** Backend deployed & smoke-verified on staging (migration + EF v3). Authenticated premium curl still manual.

## What S21 ships (backend)

- `00024_retention_simulate_rpc.sql` — `retention_simulate_rpc(p_user uuid)`
  (SECURITY DEFINER, service-role only). Engine-backed 90-day forgetting curve
  built on `engine_retrievability` / `engine_success_stability`:
  - `with_recall` — forward sim that does a `good` review whenever R decays to
    `scheduling_params.target_retention` (spaced repetition keeps R high).
  - `baseline` — same starting stability, zero further reviews (pure power-law
    decay / "without Recall").
  - `memories_saved` — nodes whose day-90 with-Recall R beats baseline by
    ΔR ≥ 0.15; persisted with a `GREATEST` monotonic guard.
  - Caches `profiles.retention_with_recall` / `retention_baseline` /
    `memories_saved` on every successful run (S22 + offline fallback).
- `retention-simulate` Edge Function — was a deploy shell (`S06`); now owns auth
  + premium gating and calls the RPC. POST, no body.

## Migration to apply (staging)

```bash
supabase db push   # applies 00024_retention_simulate_rpc.sql
```

## Edge Function to deploy

```bash
supabase functions deploy retention-simulate   # verify_jwt = true (default)
```

Depends on `_shared/{cors,auth,errors,quota,supabase}.ts` (all pre-existing).

## Expected results

| Check | Expected |
| --- | --- |
| POST no/invalid `Authorization` | 401 `unauthorized` |
| POST as **free** user | 403 `premium_required` |
| POST as **downgraded** user (`had_premium=true`, tier free) | 403 `premium_required` |
| POST as **premium** user | 200 with body below |
| `curve_points` length | 91 (day 0..90) |
| Each curve point | `{ day, with_recall (0..1), baseline (0..1) }`, `with_recall >= baseline` |
| `is_projected` | `true` when `review_days_count < 7`, else `false` |
| Premium user with 0 nodes | 200, `curve_points: []`, hero numbers 0, `memories_saved` unchanged |
| After a successful run | `profiles.retention_*` + `memories_saved` updated; re-run never lowers `memories_saved` |

### 200 response shape

```json
{
  "retention_with_recall": 82.0,
  "retention_baseline": 21.0,
  "curve_points": [
    { "day": 0, "with_recall": 0.98, "baseline": 0.98 },
    { "day": 90, "with_recall": 0.82, "baseline": 0.21 }
  ],
  "is_projected": false,
  "review_days_count": 12,
  "memories_saved": 34
}
```

## curl

```bash
# Premium JWT
curl -sS -X POST "$SUPABASE_URL/functions/v1/retention-simulate" \
  -H "Authorization: Bearer $PREMIUM_JWT" | jq '.curve_points | length'   # 91

# Free JWT
curl -sS -X POST "$SUPABASE_URL/functions/v1/retention-simulate" \
  -H "Authorization: Bearer $FREE_JWT" | jq                                # 403 premium_required
```
