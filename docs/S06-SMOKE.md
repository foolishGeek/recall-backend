# S06 Smoke Verification

**Sprint:** S06 AI Forge platform  
**Environment:** `recall-staging` (`vxbqzzebiuxzywmekdex`)  
**Date:** 2026-06-25

## Applied Migrations

- `00005_ai_quota_gate.sql` — atomic §3b gate (`ai_gate_check`, `ai_gate_consume`, `ai_log_usage`)
- `00006_embed_trigger_vault.sql` — vault-backed embed webhook for hosted Postgres

## Deployed Edge Functions

`ai-forge`, `link-preview`, `extract-pdf-text`, `quiz-generate`, `quiz-submit-answer`, `quiz-complete`, `retention-simulate`, `delete-account`, `export-user-data`, `revenuecat-webhook`

## Results

| Check | Result |
| --- | --- |
| `ai-forge` embed | `chunks_upserted: 1`, `skipped: false` |
| `ai-forge` rag_chat (empty corpus) | Fixed reply, `model: null`, no charge |
| `ai-forge` rag_chat (with chunks) | Answer + citations, model set |
| `ai-forge` summarize | 7 summary bullets |
| `ai-forge` evaluate | Quality score; `cached: true` on second call |
| `ai-forge` quiz_generate | 2 questions returned |
| `ai-forge` quiz_grade (free) | 403 `premium_required` |
| `ai-forge` summarize (empty node) | 422 `empty_context` |
| Kill-switch `ai_enabled=false` | 503 `maintenance` |
| Downgraded user (`had_premium`) | 403 `premium_required` |
| Quota gate `ai_quota_exceeded` | At 50 requests/month |
| Quota gate `overview_quota_exceeded` | At 2 overviews/month |
| Embed pipeline on `content_hash` change | `node_chunks` updated via DB trigger |
| `link-preview` YouTube | `video_id` populated |
| Shell EFs (7) | 200 `{ stub: true, sprint: "Sxx" }` |
| `revenuecat-webhook` (no JWT) | 200 stub |
| Mobile `AiService` | Typed wrappers; `dart analyze` clean |

## Notes

- Local `supabase functions serve` not run (Docker unavailable); staging curl verification used instead.
- `link-preview` `duration_sec` may be null when YouTube HTML omits `lengthSeconds` (minimal fallback still returns `video_id`).
- `extract-pdf-text` 20 MB cap enforced in function; asset-not-found path verified (full PDF upload deferred to S15).
