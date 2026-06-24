-- Sprint 06 -- make the embed DB webhook configurable on managed Postgres.
-- The S01 trigger read app.supabase_url / app.service_role_key via current_setting,
-- but hosted Supabase forbids ALTER DATABASE/ROLE SET of custom GUCs for the
-- (non-superuser) postgres role, so the pipeline could never be wired in prod.
-- This resolves both values from Supabase Vault (encrypted), falling back to the
-- GUCs for local development. Logic is otherwise identical to S01.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-4].

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION on_node_content_hash_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, vault AS $$
DECLARE
  base_url text;
  service_role_key text;
BEGIN
  IF NEW.content_hash IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.content_hash IS NOT DISTINCT FROM OLD.content_hash THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.extracted_text, '') = '' THEN
    RETURN NEW;
  END IF;

  -- Prefer Vault (works on hosted Supabase); fall back to GUCs (local dev).
  BEGIN
    SELECT decrypted_secret INTO base_url
    FROM vault.decrypted_secrets WHERE name = 'app_supabase_url';
    SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets WHERE name = 'app_service_role_key';
  EXCEPTION WHEN OTHERS THEN
    base_url := NULL;
    service_role_key := NULL;
  END;

  base_url := COALESCE(nullif(base_url, ''), nullif(current_setting('app.supabase_url', true), ''));
  service_role_key := COALESCE(nullif(service_role_key, ''), nullif(current_setting('app.service_role_key', true), ''));

  IF base_url IS NULL OR service_role_key IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := base_url || '/functions/v1/ai-forge',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    body := jsonb_build_object(
      'feature', 'embed',
      'payload', jsonb_build_object('node_id', NEW.id)
    ),
    timeout_milliseconds := 5000
  );

  RETURN NEW;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function THEN
    RETURN NEW;
  WHEN OTHERS THEN
    RAISE WARNING 'embed trigger failed for node %: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

-- Trigger binding is unchanged from S01 (AFTER INSERT OR UPDATE OF content_hash).
