-- app_sessions uses started_at (not created_at). NEW.created_at aborted the
-- trigger and rolled back the client's app_sessions insert. Use started_at,
-- and keep a soft outer guard so onboarding never breaks session logging.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION enqueue_onboarding_on_first_app_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
BEGIN
  -- Only the user's first client session. Later launches insert more rows and
  -- must not re-enqueue (ledger ON CONFLICT is a second guard).
  IF EXISTS (
    SELECT 1
    FROM app_sessions
    WHERE user_id = NEW.user_id
      AND id IS DISTINCT FROM NEW.id
  ) THEN
    RETURN NEW;
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = NEW.user_id;
  IF v_email IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO onboarding_emails (user_id, email, signup_at)
  VALUES (NEW.user_id, v_email, COALESCE(NEW.started_at, now()))
  ON CONFLICT (user_id) DO NOTHING;

  -- Best-effort instant welcome; must not roll back the ledger insert above.
  BEGIN
    PERFORM invoke_onboarding_emails();
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'invoke_onboarding_emails after app_session failed for %: %',
        NEW.user_id, SQLERRM;
  END;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Never fail the app_sessions insert because of onboarding.
    RAISE WARNING 'enqueue_onboarding_on_first_app_session failed for %: %',
      NEW.user_id, SQLERRM;
    RETURN NEW;
END;
$$;
