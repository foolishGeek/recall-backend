-- S15 — Two server-side guards for node creation/editing.
--
-- A. Stability seeding: comfort seeds initial stability on new nodes.
--    Formula: stability = comfort * 0.42 (comfort 50 → S ≈ 21 days).
--    Only fires when the node is genuinely new (stability IS NULL, state = 'new').
--
-- B. Bucket write guard: prevents INSERT/UPDATE on nodes when the target
--    bucket is not writable for the user's tier. Free users are limited to
--    their first 2 buckets (by created_at order). Ownership enforced via auth.uid().

-- ── A. Stability seeding ──

CREATE OR REPLACE FUNCTION seed_node_stability() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stability IS NULL AND NEW.state = 'new' THEN
    NEW.stability := round((NEW.comfort * 0.42)::numeric, 4);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_seed_node_stability ON nodes;
CREATE TRIGGER trigger_seed_node_stability
BEFORE INSERT ON nodes
FOR EACH ROW EXECUTE FUNCTION seed_node_stability();

-- ── B. Bucket write guard ──

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
