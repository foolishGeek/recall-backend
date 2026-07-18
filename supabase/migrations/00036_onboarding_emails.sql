-- Onboarding lifecycle emails. When a user first *confirms* sign-up (Google
-- insert already has confirmed_at; magic link sets it on verify), a row is
-- enqueued in onboarding_emails and the onboarding-emails Edge Function is
-- pinged for an instant welcome. A pg_cron job (every 2 min) is the guaranteed
-- driver: it sends the founder note ~15 min later and retries any welcome the
-- instant ping missed. The onboarding_emails table is the send-status ledger —
-- a *_sent_at is set only after a successful Zoho send. Project URL + cron
-- secret come from Supabase Vault, mirroring invoke_compute_due (00015) /
-- invoke_cleanup_exports (00027).

SET search_path = public, extensions;

-- Send-status ledger: one row per confirmed user.
CREATE TABLE IF NOT EXISTS onboarding_emails (
  user_id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email           text NOT NULL,
  signup_at       timestamptz NOT NULL DEFAULT now(),
  welcome_sent_at timestamptz,
  founder_sent_at timestamptz,
  welcome_attempts int NOT NULL DEFAULT 0,
  founder_attempts int NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  last_error      text
);

-- Service-role only (Edge Function). No policies -> RLS denies anon/authenticated.
ALTER TABLE onboarding_emails ENABLE ROW LEVEL SECURITY;

-- Atomic attempt counter used by the Edge Function before each send, so a
-- persistent failure is capped instead of looping forever.
CREATE OR REPLACE FUNCTION bump_onboarding_attempt(p_user_id uuid, p_kind text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_kind = 'welcome' THEN
    UPDATE onboarding_emails
    SET welcome_attempts = welcome_attempts + 1, last_attempt_at = now()
    WHERE user_id = p_user_id;
  ELSIF p_kind = 'founder' THEN
    UPDATE onboarding_emails
    SET founder_attempts = founder_attempts + 1, last_attempt_at = now()
    WHERE user_id = p_user_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION bump_onboarding_attempt(uuid, text) FROM PUBLIC, anon, authenticated;

-- POST to the onboarding-emails Edge Function with the X-Cron-Secret header.
CREATE OR REPLACE FUNCTION invoke_onboarding_emails() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, vault AS $$
DECLARE
  base_url text;
  cron_secret text;
BEGIN
  -- Prefer Vault (works on hosted Supabase); fall back to GUCs (local dev).
  BEGIN
    SELECT decrypted_secret INTO base_url
    FROM vault.decrypted_secrets WHERE name = 'app_supabase_url';
    SELECT decrypted_secret INTO cron_secret
    FROM vault.decrypted_secrets WHERE name = 'app_cron_secret';
  EXCEPTION WHEN OTHERS THEN
    base_url := NULL;
    cron_secret := NULL;
  END;

  base_url := COALESCE(nullif(base_url, ''), nullif(current_setting('app.supabase_url', true), ''));
  cron_secret := COALESCE(nullif(cron_secret, ''), nullif(current_setting('app.cron_secret', true), ''));

  IF base_url IS NULL OR cron_secret IS NULL THEN
    RAISE WARNING 'invoke_onboarding_emails skipped: app_supabase_url / app_cron_secret not configured';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := base_url || '/functions/v1/onboarding-emails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Cron-Secret', cron_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
EXCEPTION
  WHEN invalid_schema_name OR undefined_function THEN
    RETURN;
  WHEN OTHERS THEN
    RAISE WARNING 'invoke_onboarding_emails failed: %', SQLERRM;
    RETURN;
END;
$$;

REVOKE ALL ON FUNCTION invoke_onboarding_emails() FROM PUBLIC, anon, authenticated;

-- Enqueue on the first confirmation (works for both OAuth insert + magic-link
-- verify). Fires on every auth.users write but only acts on the null -> set
-- transition of confirmed_at, so sign-ins never re-enqueue.
CREATE OR REPLACE FUNCTION enqueue_onboarding_email() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.email IS NULL OR NEW.confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.confirmed_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO onboarding_emails (user_id, email, signup_at)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.confirmed_at, now()))
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

DROP TRIGGER IF EXISTS on_auth_user_confirmed ON auth.users;
CREATE TRIGGER on_auth_user_confirmed
AFTER INSERT OR UPDATE ON auth.users
FOR EACH ROW EXECUTE FUNCTION enqueue_onboarding_email();

-- Seed guard: mark every currently-confirmed user as already sent so existing
-- users are never blasted; only brand-new confirmations get emails from here on.
INSERT INTO onboarding_emails (user_id, email, signup_at, welcome_sent_at, founder_sent_at)
SELECT id, email, COALESCE(confirmed_at, created_at), now(), now()
FROM auth.users
WHERE confirmed_at IS NOT NULL AND email IS NOT NULL
ON CONFLICT (user_id) DO NOTHING;

-- Always-on driver: every 2 min. Idempotent reschedule (drop same-named job first).
DO $$
BEGIN
  PERFORM cron.unschedule(jobid)
  FROM cron.job
  WHERE jobname = 'onboarding-emails-2min';

  PERFORM cron.schedule(
    'onboarding-emails-2min',
    '*/2 * * * *',
    $cron$ SELECT public.invoke_onboarding_emails(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping onboarding-emails schedule';
END;
$$;
