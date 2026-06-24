-- S09: Idempotent profile bootstrap for auth users whose handle_new_user row
-- was never created (pre-trigger signups, failed trigger, etc.). Client calls
-- after session appears; mirrors handle_new_user defaults.

CREATE OR REPLACE FUNCTION ensure_profile_rpc()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p_user uuid := auth.uid();
  v_created boolean := false;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  WITH ins AS (
    INSERT INTO profiles (id)
    VALUES (p_user)
    ON CONFLICT (id) DO NOTHING
    RETURNING id
  )
  SELECT EXISTS (SELECT 1 FROM ins) INTO v_created;

  INSERT INTO subscriptions (user_id, tier)
  VALUES (p_user, 'free')
  ON CONFLICT (user_id) DO NOTHING;

  RETURN jsonb_build_object('created', v_created);
END;
$$;

REVOKE ALL ON FUNCTION ensure_profile_rpc() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION ensure_profile_rpc() TO authenticated;

-- One-time backfill for existing auth users missing profiles (run manually on staging):
-- INSERT INTO profiles (id)
-- SELECT u.id FROM auth.users u
-- WHERE NOT EXISTS (SELECT 1 FROM profiles p WHERE p.id = u.id)
-- ON CONFLICT (id) DO NOTHING;
-- INSERT INTO subscriptions (user_id, tier)
-- SELECT p.id, 'free' FROM profiles p
-- WHERE NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = p.id)
-- ON CONFLICT (user_id) DO NOTHING;
