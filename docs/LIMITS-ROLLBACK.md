# Limits profile rollback

Temporary `limits_profile = "relaxed"` raises free caps while Play / BillDesk payments settle. Server is source of truth; mobile `LimitsConfig` mirrors `app_config`.

## Active (relaxed)

| Key | Value |
|-----|-------|
| `stacks_free_monthly` | 999 |
| `buckets_free_writable` | 999 |
| `ai_quota_free_monthly` | 500 |
| `ai_overview_free_monthly` | 50 |
| `session_size_free` | 12 |
| `ai_model_free` | `gemini-2.5-flash-lite` |

## Canon (rollback target)

| Key | Value |
|-----|-------|
| `stacks_free_monthly` | 2 |
| `buckets_free_writable` | 2 |
| `ai_quota_free_monthly` | 50 |
| `ai_overview_free_monthly` | 2 |
| `session_size_free` | 8 |
| `ai_model_free` | `gemini-1.5-flash` |

## Revert (one SQL call)

```sql
SELECT public.rollback_limits_to_canon();
```

No mobile ship required — next app open reloads `app_config`.
