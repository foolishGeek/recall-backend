-- S24 · Prune expired data-export zips. pg_cron fires hourly and calls
-- invoke_cleanup_exports(), which POSTs to the cleanup-exports Edge Function with
-- the X-Cron-Secret header. The function removes the storage objects + ledger
-- rows past their 12h TTL (storage cannot be deleted from SQL). Project URL +
-- cron secret come from Supabase Vault, mirroring invoke_compute_due (00015).
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-5].

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION invoke_cleanup_exports() RETURNS void
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
    RAISE WARNING 'invoke_cleanup_exports skipped: app_supabase_url / app_cron_secret not configured';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := base_url || '/functions/v1/cleanup-exports',
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
    RAISE WARNING 'invoke_cleanup_exports failed: %', SQLERRM;
    RETURN;
END;
$$;

REVOKE ALL ON FUNCTION invoke_cleanup_exports() FROM PUBLIC, anon, authenticated;

-- Idempotent reschedule: drop any prior job with the same name, then schedule.
DO $$
BEGIN
  PERFORM cron.unschedule(jobid)
  FROM cron.job
  WHERE jobname = 'cleanup-exports-hourly';

  PERFORM cron.schedule(
    'cleanup-exports-hourly',
    '0 * * * *',
    $cron$ SELECT public.invoke_cleanup_exports(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping cleanup-exports schedule';
END;
$$;
