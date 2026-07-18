-- Fix enqueue_onboarding_on_first_app_session: an EXCEPTION handler around the
-- whole body rolled back the onboarding_emails INSERT whenever
-- invoke_onboarding_emails() failed (e.g. transient net.http_post / vault).
-- Isolate the best-effort ping so the ledger row always sticks.

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
  VALUES (NEW.user_id, v_email, COALESCE(NEW.created_at, now()))
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
END;
$$;
