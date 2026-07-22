-- Spaced-revision opt-out (per note + per bucket).
--
-- Product: every note used to be forced into the FSRS pipeline. Users now want
-- to keep plain reference notes, or skip a whole bucket, while still being able
-- to add an individual note back to revision.
--
-- Model:
--   * nodes.sr_enabled   — authoritative per-note flag; the scheduler/eligibility
--                          RPCs key on THIS (see 00046). Default true.
--   * buckets.sr_enabled — the DEFAULT applied to new notes created in the bucket
--                          (client copies it onto the node on create) plus the UI
--                          target for a "skip this whole bucket" bulk action.
--                          Not itself read by eligibility (keeps filters simple
--                          and predictable). Default true.
--
-- Backfill: NOT NULL DEFAULT true means every existing row is already in revision
-- exactly as before — behaviour is unchanged until a user opts something out.
-- Idempotent + additive; safe to re-run.

SET search_path = public, extensions;

ALTER TABLE nodes
  ADD COLUMN IF NOT EXISTS sr_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE buckets
  ADD COLUMN IF NOT EXISTS sr_enabled boolean NOT NULL DEFAULT true;

-- Hot path: due/new eligibility scans nodes by bucket among schedulable rows.
-- A partial index on the opted-OUT rows keeps them cheaply skippable without
-- bloating the common (sr_enabled = true) scans.
CREATE INDEX IF NOT EXISTS idx_nodes_sr_excluded
  ON nodes (bucket_id)
  WHERE sr_enabled = false AND deleted_at IS NULL;
