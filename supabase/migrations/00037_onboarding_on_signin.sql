-- Re-point onboarding enqueue from confirmation to first successful sign-in.
-- With mailer_autoconfirm on, auth.users.confirmed_at is set the moment a magic
-- link is *generated* (before the user clicks), so keying off confirmed_at sent
-- the welcome too early. last_sign_in_at is set only when the user actually
-- completes sign-in (clicks the link / finishes OAuth) and is updated on every
-- later sign-in, so we act only on its null -> set transition = first sign-in.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION enqueue_onboarding_email() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.email IS NULL OR NEW.last_sign_in_at IS NULL THEN
    RETURN NEW;
  END IF;
  -- Only the first ever sign-in; later sign-ins already have last_sign_in_at set.
  IF TG_OP = 'UPDATE' AND OLD.last_sign_in_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO onboarding_emails (user_id, email, signup_at)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.last_sign_in_at, now()))
  ON CONFLICT (user_id) DO NOTHING;

  -- Best-effort instant welcome; the cron is the guaranteed driver + retry.
  PERFORM invoke_onboarding_emails();

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'enqueue_onboarding_email failed for %: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

-- Rebind: fire on first sign-in (last_sign_in_at) instead of confirmation.
DROP TRIGGER IF EXISTS on_auth_user_confirmed ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_signed_in ON auth.users;
CREATE TRIGGER on_auth_user_signed_in
AFTER INSERT OR UPDATE OF last_sign_in_at ON auth.users
FOR EACH ROW EXECUTE FUNCTION enqueue_onboarding_email();
