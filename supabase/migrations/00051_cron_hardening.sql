-- Make the Drop cron observable instead of silently dead.
--
-- invoke_compute_due() used to RAISE WARNING and RETURN on missing Vault secrets
-- or an unavailable pg_net, and never recorded the pg_net request id. In prod
-- that means "no Drops" with nothing queryable to explain why. Now every run
-- writes a cron_run_log row (ok / misconfigured / skipped / error) so a broken
-- pipeline is a one-line SELECT away. Also schedules daily device-token pruning.
--
-- Deploy requirement (unchanged): Vault secrets app_supabase_url + app_cron_secret
-- must be set, and app_cron_secret MUST equal the edge function's CRON_SECRET env.

SET search_path = public, extensions;

-- Auditable cron history. Internal only: RLS on, no policies -> unreachable by
-- anon/authenticated; definer functions and service_role still write/read.
CREATE TABLE IF NOT EXISTS cron_run_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job text NOT NULL,
  status text NOT NULL,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cron_run_log_job_created
  ON cron_run_log (job, created_at DESC);

ALTER TABLE cron_run_log ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION invoke_compute_due() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, vault AS $$
DECLARE
  base_url text;
  cron_secret text;
  v_request_id bigint;
BEGIN
  -- Prefer Vault (hosted); fall back to GUCs (local dev).
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
    INSERT INTO cron_run_log (job, status, detail)
    VALUES ('compute-due', 'misconfigured',
            'app_supabase_url / app_cron_secret not configured in Vault or GUC');
    RETURN;
  END IF;

  BEGIN
    SELECT net.http_post(
      url := base_url || '/functions/v1/compute-due',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Cron-Secret', cron_secret
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    ) INTO v_request_id;

    INSERT INTO cron_run_log (job, status, detail)
    VALUES ('compute-due', 'ok', 'net_request_id=' || COALESCE(v_request_id::text, 'null'));
  EXCEPTION
    WHEN invalid_schema_name OR undefined_function THEN
      INSERT INTO cron_run_log (job, status, detail)
      VALUES ('compute-due', 'skipped', 'pg_net unavailable');
    WHEN OTHERS THEN
      INSERT INTO cron_run_log (job, status, detail)
      VALUES ('compute-due', 'error', SQLERRM);
  END;

  -- Keep the log bounded (cheap; runs every 5 min).
  DELETE FROM cron_run_log WHERE created_at < now() - interval '30 days';
END;
$$;

REVOKE ALL ON FUNCTION invoke_compute_due() FROM PUBLIC, anon, authenticated;

-- Daily device-token hygiene (00050.prune_stale_device_tokens).
CREATE OR REPLACE FUNCTION invoke_prune_device_tokens() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_deleted integer;
BEGIN
  v_deleted := prune_stale_device_tokens();
  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('prune-device-tokens', 'ok', 'deleted=' || v_deleted);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO cron_run_log (job, status, detail)
  VALUES ('prune-device-tokens', 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION invoke_prune_device_tokens() FROM PUBLIC, anon, authenticated;

-- Schedule the daily prune (03:17 UTC to avoid top-of-hour contention).
DO $$
BEGIN
  PERFORM cron.unschedule(jobid)
  FROM cron.job
  WHERE jobname = 'prune-device-tokens-daily';

  PERFORM cron.schedule(
    'prune-device-tokens-daily',
    '17 3 * * *',
    $cron$ SELECT public.invoke_prune_device_tokens(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping prune-device-tokens schedule';
END;
$$;
