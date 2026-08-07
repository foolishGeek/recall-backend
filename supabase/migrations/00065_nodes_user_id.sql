-- Phase 7: denormalise nodes.user_id so ownership and retrieval no longer
-- require a buckets join on every hot path.
--
-- Additive only: bucket_id stays NOT NULL. A later migration may open
-- unassigned notes; until then every node still lives in a bucket, and this
-- column is kept in sync by a trigger so dual-write never drifts.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Column + backfill
-- ---------------------------------------------------------------------

ALTER TABLE nodes
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES profiles(id) ON DELETE CASCADE;

COMMENT ON COLUMN nodes.user_id IS
  'Owner denormalised from buckets.user_id. Always set while bucket_id is required; enables future bucketless notes.';

-- Existing rows: copy from the owning bucket. The writable-bucket trigger
-- refuses UPDATEs when auth.uid() is null (migration context), so disable it
-- for the backfill only.
ALTER TABLE nodes DISABLE TRIGGER trigger_check_node_bucket_writable;

UPDATE nodes n
SET user_id = b.user_id
FROM buckets b
WHERE n.bucket_id = b.id
  AND n.user_id IS NULL;

ALTER TABLE nodes ENABLE TRIGGER trigger_check_node_bucket_writable;

-- Orphans should not exist under current constraints; refuse to proceed if any
-- remain so we never set NOT NULL over NULL owners.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM nodes WHERE user_id IS NULL) THEN
    RAISE EXCEPTION '00065_nodes_user_id: cannot set NOT NULL; some nodes lack a resolvable bucket owner';
  END IF;
END $$;

ALTER TABLE nodes
  ALTER COLUMN user_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_nodes_user_active
  ON nodes (user_id)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Dual-write trigger: keep user_id aligned with the bucket owner
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION nodes_sync_user_id()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Only when a bucket is present (always today). Leave an explicit NEW.user_id
  -- alone when bucket_id is somehow cleared by a future path.
  IF NEW.bucket_id IS NOT NULL THEN
    IF TG_OP = 'INSERT'
       OR NEW.bucket_id IS DISTINCT FROM OLD.bucket_id
       OR NEW.user_id IS NULL THEN
      SELECT b.user_id INTO NEW.user_id
      FROM buckets b
      WHERE b.id = NEW.bucket_id;
      IF NEW.user_id IS NULL THEN
        RAISE EXCEPTION 'nodes_sync_user_id: bucket % not found', NEW.bucket_id;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_nodes_sync_user_id ON nodes;
CREATE TRIGGER trg_nodes_sync_user_id
  BEFORE INSERT OR UPDATE OF bucket_id, user_id ON nodes
  FOR EACH ROW EXECUTE FUNCTION nodes_sync_user_id();

REVOKE ALL ON FUNCTION nodes_sync_user_id() FROM PUBLIC, anon, authenticated;
