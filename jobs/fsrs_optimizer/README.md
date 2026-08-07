# FSRS per-user weight optimizer (Phase 2 — flagged)

Learns each user's own FSRS-6 weights from their real review history using the
official [`fsrs-optimizer`](https://github.com/open-spaced-repetition/fsrs-optimizer),
proves whether they beat the published defaults, and records the evidence.

## Why a Python job (not SQL)

FSRS weight optimization is gradient descent over a user's full review log. The
reference implementation is the `fsrs-optimizer` package; reimplementing it in
Postgres would be slow and would drift from upstream. So the math lives here and
talks to the DB only through service-role RPCs.

## Safety model — no dead lever, no silent influence

```
export_review_history_rpc  ──►  optimize.py  ──►  fsrs_record_candidate_rpc
                                    │                     │
                                    │              fsrs_weight_candidates
                                    │              (weights + Brier evidence)
                                    ▼
                            fsrs_adopt_candidate_rpc
                       (adopt ONLY if beats default by margin
                        AND kill-switch fsrs_per_user_weights_enabled = ON)
```

- Optimized weights are stored as **candidates with evidence** (Brier score of
  candidate vs default on a held-out 20% split).
- `fsrs_adopt_candidate_rpc` marks a candidate `adopted` **only** if
  `brier_candidate < brier_default - fsrs_adopt_brier_margin` and the kill-switch
  is on. Otherwise it's `rejected`.
- **Adopted weights do NOT yet change scheduling.** Applying them to the live
  engine (threading an optional 21-element weights array through the `IMMUTABLE`
  engine helpers + the three RPC boundaries, `COALESCE(p_w[i+1], default)`,
  resolved bucket > user > global) is the final, separately-shipped step, also
  gated by `fsrs_per_user_weights_enabled`. Until that ships, this pipeline is
  measure-and-prove only.

## Run

```bash
cd recall-backend/jobs/fsrs_optimizer
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export SUPABASE_URL=...            # project URL
export SUPABASE_SERVICE_ROLE_KEY=...

# Dry run (no writes) to see who qualifies and how weights would score:
python optimize.py --all --dry-run

# Optimize one user and store the candidate + evidence:
python optimize.py --user <uuid>

# Batch, and run the adopt gate (still a no-op unless the kill-switch is ON):
python optimize.py --all --min-reviews 400 --adopt
```

## Enabling adoption (owner)

1. Review candidates: `select user_id, weights_version, n_reviews, brier_candidate,
   brier_default, status from fsrs_weight_candidates order by created_at desc;`
2. When confident, flip the kill-switch:
   `update app_config set value = 'true' where key = 'fsrs_per_user_weights_enabled';`
3. Ship + enable the live-threading step (see migration `00058` header) so
   adopted weights actually feed the scheduler. Kill-switch OFF instantly
   reverts everyone to the published defaults.
```
