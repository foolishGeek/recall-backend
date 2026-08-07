#!/usr/bin/env python3
"""Phase 2 per-user FSRS weight optimizer (offline job).

Pipeline (never touches the live scheduling path):

  1. Pull a user's review log via the `export_review_history_rpc` RPC.
  2. Optimize FSRS-6 weights on that log with the official `fsrs-optimizer`.
  3. Measure calibration (Brier score) for BOTH the optimized weights and the
     published defaults, on a held-out split of the same log.
  4. Write the candidate + evidence back via `fsrs_record_candidate_rpc`.
  5. (Optional) call `fsrs_adopt_candidate_rpc` — which adopts ONLY if the
     candidate beats default by the configured margin AND the kill-switch
     (`fsrs_per_user_weights_enabled`) is ON.

This job produces *evidence*. Adopted weights are recorded but do not silently
change any user's reviews until the live-threading step is shipped and enabled.

Requirements: see requirements.txt. Needs SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY.

Usage:
    python optimize.py --user <uuid>            # one user
    python optimize.py --all --min-reviews 400  # every active user
    python optimize.py --user <uuid> --adopt    # also run the adopt gate
"""
from __future__ import annotations

import argparse
import math
import os
import sys
from datetime import datetime, timezone

try:
    from supabase import create_client
except ImportError:  # pragma: no cover
    sys.exit("Missing dep: pip install -r requirements.txt (supabase)")

try:
    # Official optimizer + scheduler (py-fsrs / fsrs-optimizer)
    from fsrs_optimizer import Optimizer  # type: ignore
    from fsrs import FSRS, Card, Rating, ReviewLog  # type: ignore
except ImportError:  # pragma: no cover
    Optimizer = None  # allow --dry-run without the heavy deps installed


# FSRS-6 published defaults (open-spaced-repetition DEFAULT_PARAMETERS).
DEFAULT_WEIGHTS = [
    0.2172, 1.1771, 3.2602, 16.1507, 7.0114, 0.57, 2.0966, 0.0069, 1.5261,
    0.112, 1.0178, 1.849, 0.1133, 0.3127, 2.2934, 0.2191, 3.0004, 0.7536,
    0.3332, 0.1437, 0.2,
]

MIN_TRAIN_REVIEWS = 400  # fsrs-optimizer needs a healthy history to be trustworthy


def client():
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY")
    return create_client(url, key)


def fetch_history(sb, user_id: str) -> list[dict]:
    res = sb.rpc("export_review_history_rpc", {"p_user": user_id}).execute()
    rows = res.data or []
    for r in rows:
        r["reviewed_at"] = datetime.fromisoformat(
            r["reviewed_at"].replace("Z", "+00:00")
        )
    return rows


def _power_forgetting(stability: float, elapsed_days: float) -> float:
    """FSRS-6 retrievability R(t) = (1 + F * t/S)^C."""
    if stability <= 0:
        return 0.0
    F = 19.0 / 81.0
    C = -0.5
    return (1 + F * (elapsed_days / stability)) ** C


def brier_for_weights(history: list[dict], weights: list[float]) -> tuple[float, int]:
    """Replay each card through FSRS with `weights`; Brier = mean (p - y)^2 over
    predictions (excluding each card's first, unpredictable review)."""
    if Optimizer is None:
        # dry-run stub
        return (0.0, 0)

    scheduler = FSRS(parameters=tuple(weights))
    by_card: dict[str, list[dict]] = {}
    for r in history:
        by_card.setdefault(r["card_id"], []).append(r)

    sq_err = 0.0
    n = 0
    for _card_id, logs in by_card.items():
        logs.sort(key=lambda x: x["reviewed_at"])
        card = Card()
        last_at = None
        for i, log in enumerate(logs):
            now = log["reviewed_at"]
            if i > 0 and card.stability:
                elapsed = (now - last_at).total_seconds() / 86400.0
                p = _power_forgetting(card.stability, max(elapsed, 0))
                y = 1.0 if log["rating"] != 1 else 0.0
                sq_err += (p - y) ** 2
                n += 1
            card, _rl = scheduler.review_card(card, Rating(log["rating"]), now)
            last_at = now

    return (sq_err / n if n else float("nan"), n)


def optimize_user(sb, user_id: str, min_reviews: int, adopt: bool, dry: bool):
    history = fetch_history(sb, user_id)
    if len(history) < min_reviews:
        print(f"[skip] {user_id}: {len(history)} reviews < {min_reviews}")
        return

    # Hold out the most recent 20% for an honest calibration comparison.
    history.sort(key=lambda x: x["reviewed_at"])
    split = int(len(history) * 0.8)
    train, test = history[:split], history[split:]

    if dry or Optimizer is None:
        weights = list(DEFAULT_WEIGHTS)
        print(f"[dry] {user_id}: would optimize on {len(train)} reviews")
    else:
        opt = Optimizer()
        opt.define_model()
        weights = list(opt.train(train))  # returns 21 FSRS-6 params

    brier_cand, _ = brier_for_weights(test, weights)
    brier_def, n_eval = brier_for_weights(test, DEFAULT_WEIGHTS)
    print(
        f"[eval] {user_id}: n={n_eval} brier_cand={brier_cand:.4f} "
        f"brier_default={brier_def:.4f} "
        f"{'BEATS' if brier_cand < brier_def else 'worse'} default"
    )

    if dry:
        return

    rec = sb.rpc(
        "fsrs_record_candidate_rpc",
        {
            "p_user": user_id,
            "p_weights": [round(w, 6) for w in weights],
            "p_n_reviews": n_eval,
            "p_brier_candidate": round(brier_cand, 6),
            "p_brier_default": round(brier_def, 6),
        },
    ).execute()
    candidate_id = rec.data
    print(f"[saved] candidate {candidate_id}")

    if adopt:
        res = sb.rpc(
            "fsrs_adopt_candidate_rpc", {"p_candidate_id": candidate_id}
        ).execute()
        print(f"[adopt] {res.data}")


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--user", help="single user uuid")
    g.add_argument("--all", action="store_true", help="all active users")
    ap.add_argument("--min-reviews", type=int, default=MIN_TRAIN_REVIEWS)
    ap.add_argument("--adopt", action="store_true", help="run the adopt gate")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    sb = client()

    if args.user:
        optimize_user(sb, args.user, args.min_reviews, args.adopt, args.dry_run)
        return

    # --all: users with reviews in the last 30 days.
    rows = (
        sb.table("reviews")
        .select("user_id")
        .gte("reviewed_at", datetime.now(timezone.utc).isoformat())
        .execute()
    )
    users = sorted({r["user_id"] for r in (rows.data or [])})
    print(f"{len(users)} users")
    for u in users:
        try:
            optimize_user(sb, u, args.min_reviews, args.adopt, args.dry_run)
        except Exception as e:  # keep the batch going
            print(f"[error] {u}: {e}")


if __name__ == "__main__":
    main()
