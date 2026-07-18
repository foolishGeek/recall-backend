-- Re-point onboarding enqueue to the first real *client* sign-in.
--
-- With enable_confirmations=false (autoconfirm), GoTrue sets confirmed_at,
-- last_sign_in_at, AND even creates an auth.sessions row the moment a magic
-- link is *requested* — before the user clicks. So keying off auth.users
-- (00036 confirmed_at / 00037 last_sign_in_at) sent welcome alongside the
-- magic-link email.
--
-- app_sessions is written only by the mobile client after it actually holds a
-- session (magic-link deep link completed, or Google/Apple OAuth finished).
-- First INSERT into app_sessions for a user = successful sign-up.

SET search_path = public, extensions;

-- Drop the auth.users trigger — it fires too early under autoconfirm.
DROP TRIGGER IF EXISTS on_auth_user_signed_in ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_confirmed ON auth.users;

-- Keep the old function around only so a stray reference doesn't break; it
-- becomes a no-op. Prefer the app_sessions path below.
CREATE OR REPLACE FUNCTION enqueue_onboarding_email() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN NEW;
END;
$$;

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

  -- Best-effort instant welcome; cron remains the guaranteed driver + retry.
  PERFORM invoke_onboarding_emails();

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'enqueue_onboarding_on_first_app_session failed for %: %',
      NEW.user_id, SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_first_app_session_onboarding ON app_sessions;
CREATE TRIGGER on_first_app_session_onboarding
AFTER INSERT ON app_sessions
FOR EACH ROW
EXECUTE FUNCTION enqueue_onboarding_on_first_app_session();

REVOKE ALL ON FUNCTION enqueue_onboarding_on_first_app_session() FROM PUBLIC, anon, authenticated;
