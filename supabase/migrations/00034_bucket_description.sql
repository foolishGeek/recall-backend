-- Add an optional, user-authored description to buckets. Shown on the bucket
-- preview card and collected in the create-bucket flow. Nullable, no backfill;
-- RLS is unchanged (owner-only policies already key off user_id).

SET search_path = public, extensions;

ALTER TABLE buckets ADD COLUMN IF NOT EXISTS description text;
