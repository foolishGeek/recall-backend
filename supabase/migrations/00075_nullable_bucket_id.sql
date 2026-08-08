-- Recall · 00075 — notes may live outside a bucket.
--
-- Ask Aura / summarize / retrieval already understand scope kind "nodes". What
-- blocked a note with no bucket was the schema: nodes.bucket_id was NOT NULL
-- and the free-tier write guard assumed every write had a bucket. Opening that
-- column lets a note exist on its own without changing how bucketed notes work.

BEGIN;

ALTER TABLE nodes ALTER COLUMN bucket_id DROP NOT NULL;

/**
 * Free-tier write guard. A note with no bucket is charged against the owner's
 * account (user_id), not a bucket rank — the stack-limit path only applies when
 * a bucket is present.
 */
CREATE OR REPLACE FUNCTION check_node_bucket_writable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id uuid;
  v_limit integer;
  v_rank bigint;
BEGIN
  -- Unassigned note: owner must be the caller; no bucket rank to check.
  IF NEW.bucket_id IS NULL THEN
    IF NEW.user_id IS NULL OR NEW.user_id != auth.uid() THEN
      RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  SELECT b.user_id INTO v_user_id
  FROM buckets b
  WHERE b.id = NEW.bucket_id AND b.deleted_at IS NULL;

  IF v_user_id IS NULL OR v_user_id != auth.uid() THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0001';
  END IF;

  v_limit := writable_bucket_count_limit(v_user_id);
  IF v_limit >= 999 THEN
    RETURN NEW;
  END IF;

  SELECT bucket_rank_for_user(NEW.bucket_id) INTO v_rank;
  IF v_rank IS NULL OR v_rank > v_limit THEN
    RAISE EXCEPTION 'free_tier_bucket_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- Keep user_id when a note is detached from its bucket.
CREATE OR REPLACE FUNCTION nodes_sync_user_id()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
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
  ELSIF NEW.user_id IS NULL THEN
    -- Detached note with no owner is not allowed — auth.uid() is the caller.
    NEW.user_id := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON COLUMN nodes.bucket_id IS
  'Optional. Null means the note is not in any bucket; retrieval uses nodes.user_id.';

COMMIT;
