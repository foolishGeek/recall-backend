-- Test double for pg_cron. Stores schedules in a real cron.job table so
-- migrations can unschedule-then-schedule idempotently, but never fires them.
CREATE SCHEMA IF NOT EXISTS cron;

CREATE TABLE IF NOT EXISTS cron.job (
  jobid    bigserial PRIMARY KEY,
  schedule text,
  command  text,
  nodename text NOT NULL DEFAULT 'localhost',
  nodeport integer NOT NULL DEFAULT 5432,
  database text NOT NULL DEFAULT current_database(),
  username text NOT NULL DEFAULT CURRENT_USER,
  active   boolean NOT NULL DEFAULT true,
  jobname  text UNIQUE
);

CREATE FUNCTION cron.schedule(job_name text, schedule text, command text)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO cron.job (jobname, schedule, command)
  VALUES (job_name, schedule, command)
  ON CONFLICT (jobname)
  DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
  RETURNING jobid INTO v_id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION cron.schedule(schedule text, command text)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT cron.schedule(md5(command), schedule, command);
$$;

CREATE FUNCTION cron.unschedule(job_id bigint)
RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM cron.job WHERE jobid = job_id;
  RETURN true;
END;
$$;

CREATE FUNCTION cron.unschedule(job_name text)
RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM cron.job WHERE jobname = job_name;
  RETURN true;
END;
$$;
