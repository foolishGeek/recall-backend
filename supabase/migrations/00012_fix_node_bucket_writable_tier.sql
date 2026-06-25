-- S15 hotfix — check_node_bucket_writable referenced a non-existent
-- profiles.subscription_tier column, which made EVERY node INSERT fail with
-- "column p.subscription_tier does not exist". Tier lives in `subscriptions`
-- (see check_bucket_limit in 00001). Re-define the function with the canonical
-- profiles LEFT JOIN subscriptions lookup. Idempotent (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION check_node_bucket_writable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user_id uuid;
  v_tier subscription_tier;
  v_rank bigint;
BEGIN
  SELECT b.user_id INTO v_user_id
  FROM buckets b
  WHERE b.id = NEW.bucket_id AND b.deleted_at IS NULL;

  IF v_user_id IS NULL OR v_user_id != auth.uid() THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(s.tier, 'free'::subscription_tier) INTO v_tier
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = v_user_id;

  IF v_tier = 'free' THEN
    SELECT count(*) INTO v_rank
    FROM buckets
    WHERE user_id = v_user_id
      AND deleted_at IS NULL
      AND created_at <= (SELECT created_at FROM buckets WHERE id = NEW.bucket_id);
    IF v_rank > 2 THEN
      RAISE EXCEPTION 'free_tier_bucket_limit' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_node_bucket_writable ON nodes;
CREATE TRIGGER trigger_check_node_bucket_writable
BEFORE INSERT OR UPDATE OF bucket_id ON nodes
FOR EACH ROW EXECUTE FUNCTION check_node_bucket_writable();
