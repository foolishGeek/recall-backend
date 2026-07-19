# Limits profile rollback

Temporary `limits_profile = "relaxed"` raises free caps and **suppresses paywall UI** while Play / BillDesk payments settle. Server is source of truth; mobile `LimitsConfig` mirrors `app_config` on splash + app resume.

**After the paywall-suppression wiring ships once, flipping relaxed ↔ canon is SQL-only — no app release.**

## Active (relaxed)

| Key | Value |
|-----|-------|
| `stacks_free_monthly` | 999 |
| `buckets_free_writable` | 999 |
| `ai_quota_free_monthly` | 500 |
| `ai_overview_free_monthly` | 50 |
| `session_size_free` | 12 |
| `ai_model_free` | `gemini-2.5-flash-lite` |

While `limits_profile = "relaxed"`:

- **No paywall CTAs** (Settings upgrade, Today unlock, Insights/You upgrade, bucket FAB lock, AI upgrade routes) — `TierService.openPaywall()` no-ops.
- **Premium feature access** for free/downgraded: Insights + You simulation, uncapped buckets, AI under raised free quotas (downgraded AI block skipped).
- **Quiz stays WIP** — non-premium taps still show `QuizInProgressSheet` (not paywall, not full quiz). Quiz Edge Functions remain `premium_required`.

## Canon (rollback target)

| Key | Value |
|-----|-------|
| `stacks_free_monthly` | 2 |
| `buckets_free_writable` | 2 |
| `ai_quota_free_monthly` | 50 |
| `ai_overview_free_monthly` | 2 |
| `session_size_free` | 8 |
| `ai_model_free` | `gemini-1.5-flash` |

## Revert to normal (one SQL call — no app release)

```sql
SELECT public.rollback_limits_to_canon();
```

Sets `limits_profile = "canon"` and restores numeric + model snapshots. Next splash / resume reload picks it up; Edge Functions and RPCs read `app_config` per request.

## Re-enable temporary free later (still no release)

Upsert `limits_profile = "relaxed"` plus the raised caps (same keys as migration `00043`), or re-apply the relaxed seed values from `LIMITS-ROLLBACK` / `00043_limits_profile_relaxed.sql`.
