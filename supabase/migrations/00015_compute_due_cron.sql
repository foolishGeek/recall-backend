-- S16 · Schedule the Recall Drop pipeline. pg_cron fires every 15 min and calls
-- invoke_compute_due(), which POSTs to the compute-due Edge Function with the
-- X-Cron-Secret header. The project URL + cron secret are read from Supabase
-- Vault (encrypted), mirroring the embed trigger (00006); the secret never lands
-- in the cron.job table. Deploy step: store Vault secrets app_supabase_url +
-- app_cron_secret on each project (see docs/S16-SMOKE.md).
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-9].

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION invoke_compute_due() RETURNS void
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
    RAISE WARNING 'invoke_compute_due skipped: app_supabase_url / app_cron_secret not configured';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := base_url || '/functions/v1/compute-due',
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
    RAISE WARNING 'invoke_compute_due failed: %', SQLERRM;
    RETURN;
END;
$$;

REVOKE ALL ON FUNCTION invoke_compute_due() FROM PUBLIC, anon, authenticated;

-- Idempotent reschedule: drop any prior job with the same name, then schedule.
DO $$
BEGIN
  PERFORM cron.unschedule(jobid)
  FROM cron.job
  WHERE jobname = 'compute-due-15min';

  PERFORM cron.schedule(
    'compute-due-15min',
    '*/15 * * * *',
    $cron$ SELECT public.invoke_compute_due(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping compute-due schedule';
END;
$$;
