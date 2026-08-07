-- Make embedding durable and chunk replacement atomic.
--
-- Two failure modes this closes:
--
-- 1. The content_hash trigger fired a bare pg_net POST. If pg_net was missing,
--    the function was cold, or the isolate died, the note was simply never
--    embedded -- silently unsearchable, with nothing to query to find out.
--    ai_embed_queue records the intent, so a miss is a visible row rather than
--    a lost event, and it is retried with backoff until it succeeds or fails
--    loudly.
--
-- 2. embed() deleted a node's chunks and then inserted the new ones as two
--    separate statements. A failure in between left the note with zero chunks.
--    node_chunks_replace does both in one transaction.
--
-- Also adds the columns Phase 3's chunker needs: a real token_count instead of
-- a 4-chars-per-token guess, and the context header that was prefixed to the
-- embedded text so what went into the vector is reproducible.
--
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-4].

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- node_chunks: real token counts, reproducible embed input
-- ---------------------------------------------------------------------

-- content stays the note's own words so citations quote it verbatim; the vector
-- is built from context_header || content, and storing the header (not the
-- concatenation) keeps that exact without duplicating the body.
ALTER TABLE node_chunks
  ADD COLUMN IF NOT EXISTS token_count integer,
  ADD COLUMN IF NOT EXISTS context_header text;

COMMENT ON COLUMN node_chunks.token_count IS
  'Tokens in the embedded text, counted with the model tokenizer.';
COMMENT ON COLUMN node_chunks.context_header IS
  'Prefixed to content before embedding (note title, bucket). NULL for pre-Phase-3 rows.';

-- ---------------------------------------------------------------------
-- ai_embed_queue
-- ---------------------------------------------------------------------

DO $$
BEGIN
  CREATE TYPE ai_embed_status AS ENUM ('pending', 'processing', 'done', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- One row per source, not one per event: re-saving a note ten times should
-- leave one thing to do, and the row doubles as the current embed status.
CREATE TABLE IF NOT EXISTS ai_embed_queue (
  id              bigserial PRIMARY KEY,
  source_kind     text NOT NULL DEFAULT 'node',
  source_id       uuid NOT NULL,
  -- Why this is queued, which decides whether the owner pays for it.
  -- 'content_change' is the user changing their note, and costs an AI request
  -- per [D-AI-3]. 'reindex' is us rebuilding vectors for content they already
  -- paid to embed once -- a better chunker, a new model -- and must be free, or
  -- a migration would quietly spend everyone's monthly allowance.
  reason          text NOT NULL DEFAULT 'content_change'
                    CHECK (reason IN ('content_change', 'reindex')),
  status          ai_embed_status NOT NULL DEFAULT 'pending',
  attempts        integer NOT NULL DEFAULT 0,
  last_error      text,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  claimed_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_kind, source_id)
);

-- The drainer's only query: what is due, oldest first.
CREATE INDEX IF NOT EXISTS idx_ai_embed_queue_due
  ON ai_embed_queue (next_attempt_at)
  WHERE status IN ('pending', 'processing');

CREATE INDEX IF NOT EXISTS idx_ai_embed_queue_failed
  ON ai_embed_queue (updated_at DESC)
  WHERE status = 'failed';

-- Internal: RLS on with no policies makes it unreachable by anon/authenticated,
-- while definer functions and service_role still work.
ALTER TABLE ai_embed_queue ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS set_ai_embed_queue_updated_at ON ai_embed_queue;
CREATE TRIGGER set_ai_embed_queue_updated_at
  BEFORE UPDATE ON ai_embed_queue
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Queue API
-- ---------------------------------------------------------------------

-- Marks a source as needing (re-)embedding. Resets attempts so a source that
-- previously exhausted its retries gets a fresh start when its content changes.
CREATE OR REPLACE FUNCTION ai_embed_enqueue(
  p_source_id uuid,
  p_source_kind text DEFAULT 'node',
  p_reason text DEFAULT 'content_change'
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO ai_embed_queue (source_kind, source_id, reason, status, attempts,
                              last_error, next_attempt_at, claimed_at)
  VALUES (p_source_kind, p_source_id, p_reason, 'pending', 0, NULL, now(), NULL)
  ON CONFLICT (source_kind, source_id) DO UPDATE
    SET reason = CASE
          -- A real edit always wins: the user changed the note, so the work is
          -- theirs even if a reindex was already waiting.
          WHEN p_reason = 'content_change' THEN p_reason
          -- A reindex must not erase an edit that has not been embedded yet, or
          -- the user's change would silently become our unbilled work.
          WHEN ai_embed_queue.status IN ('pending', 'processing')
            THEN ai_embed_queue.reason
          -- Otherwise the previous reason is settled history.
          ELSE p_reason
        END,
        status = 'pending', attempts = 0, last_error = NULL,
        next_attempt_at = now(), claimed_at = NULL
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Hands out work. SKIP LOCKED means the cron backstop and the wake-up call the
-- trigger fires can run at the same time without doing the same node twice.
--
-- A 'processing' row older than the reclaim window is picked up again: that is a
-- worker that died mid-flight, and the alternative is a note stuck forever.
CREATE OR REPLACE FUNCTION ai_embed_claim(p_limit integer DEFAULT 25)
RETURNS TABLE (id bigint, source_kind text, source_id uuid, reason text, attempts integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  reclaim_after interval := make_interval(
    mins => GREATEST(app_config_int('ai_embed_reclaim_minutes', 10), 1));
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT q.id
    FROM ai_embed_queue q
    WHERE (q.status = 'pending' AND q.next_attempt_at <= now())
       OR (q.status = 'processing' AND q.claimed_at < now() - reclaim_after)
    ORDER BY q.next_attempt_at
    LIMIT GREATEST(p_limit, 1)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE ai_embed_queue q
  SET status = 'processing', claimed_at = now()
  FROM due
  WHERE q.id = due.id
  RETURNING q.id, q.source_kind, q.source_id, q.reason, q.attempts;
END;
$$;

-- Closes out an attempt. A failure backs off exponentially and only gives up
-- into 'failed' once the attempt budget is spent, so a transient provider
-- outage costs nothing but time while a genuinely broken note stays visible.
CREATE OR REPLACE FUNCTION ai_embed_complete(
  p_id bigint,
  p_ok boolean,
  p_error text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  max_attempts integer := GREATEST(app_config_int('ai_embed_max_attempts', 5), 1);
  base_delay   integer := GREATEST(app_config_int('ai_embed_backoff_seconds', 60), 1);
  v_attempts   integer;
BEGIN
  IF p_ok THEN
    UPDATE ai_embed_queue
    SET status = 'done', last_error = NULL, claimed_at = NULL
    WHERE id = p_id;
    RETURN;
  END IF;

  SELECT attempts + 1 INTO v_attempts FROM ai_embed_queue WHERE id = p_id;
  IF v_attempts IS NULL THEN RETURN; END IF;

  UPDATE ai_embed_queue
  SET attempts        = v_attempts,
      last_error      = left(COALESCE(p_error, 'unknown'), 1000),
      claimed_at      = NULL,
      status          = CASE WHEN v_attempts >= max_attempts THEN 'failed'::ai_embed_status
                             ELSE 'pending'::ai_embed_status END,
      -- 1m, 2m, 4m, 8m ... capped so a long outage does not park work for days.
      next_attempt_at = now() + make_interval(
        secs => LEAST(base_delay * power(2, v_attempts - 1), 3600)::double precision)
  WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION ai_embed_enqueue(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ai_embed_claim(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ai_embed_complete(bigint, boolean, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Atomic chunk replacement
-- ---------------------------------------------------------------------

-- Replaces a node's chunks in one statement pair inside one transaction, so the
-- note is never observably chunk-less. An empty array is a valid input: it is
-- how a note whose text was cleared stops being searchable under stale content.
--
-- p_chunks: [{ chunk_index, content, context_header, token_count, embedding }]
-- where embedding is a JSON array of floats.
CREATE OR REPLACE FUNCTION node_chunks_replace(p_node_id uuid, p_chunks jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_count integer;
BEGIN
  IF p_chunks IS NULL OR jsonb_typeof(p_chunks) <> 'array' THEN
    RAISE EXCEPTION 'node_chunks_replace: p_chunks must be a JSON array';
  END IF;

  -- Serialise concurrent replacements for the same node; two drainers racing
  -- here would interleave delete and insert and leave a mixed generation.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_node_id::text, 0));

  DELETE FROM node_chunks WHERE node_id = p_node_id;

  INSERT INTO node_chunks (node_id, chunk_index, content, context_header,
                           token_count, embedding)
  SELECT p_node_id,
         (elem->>'chunk_index')::integer,
         elem->>'content',
         nullif(elem->>'context_header', ''),
         (elem->>'token_count')::integer,
         (elem->>'embedding')::vector
  FROM jsonb_array_elements(p_chunks) AS elem;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION node_chunks_replace(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- The trigger now enqueues instead of firing the request itself
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION on_node_content_hash_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, vault AS $$
DECLARE
  base_url         text;
  cron_secret      text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.content_hash IS NOT DISTINCT FROM OLD.content_hash THEN
    RETURN NEW;
  END IF;

  -- A brand new note with no content has nothing to embed and no stale chunks to
  -- clear, so queueing it would only add noise.
  IF TG_OP = 'INSERT' AND NEW.content_hash IS NULL THEN
    RETURN NEW;
  END IF;

  -- An update to empty IS queued: that case has to clear the old chunks, or the
  -- note keeps matching searches for content it no longer has.
  PERFORM ai_embed_enqueue(NEW.id, 'node');

  -- Best-effort nudge so a note is usually embedded within seconds rather than
  -- waiting for the next cron tick. The queue is what guarantees it happens, so
  -- every failure here is safe to swallow.
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
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := base_url || '/functions/v1/embed-drain',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Cron-Secret', cron_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 5000
  );

  RETURN NEW;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function THEN
    RETURN NEW;
  WHEN OTHERS THEN
    RAISE WARNING 'embed wake-up failed for node % (queued anyway): %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- Cron backstop
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION invoke_embed_drain() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, vault AS $$
DECLARE
  base_url     text;
  cron_secret  text;
  v_due        integer;
  v_request_id bigint;
BEGIN
  SELECT count(*) INTO v_due
  FROM ai_embed_queue
  WHERE status = 'pending' AND next_attempt_at <= now();

  IF v_due = 0 THEN
    RETURN;   -- nothing to do; do not log a row every minute
  END IF;

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
    VALUES ('embed-drain', 'misconfigured',
            'app_supabase_url / app_cron_secret not configured in Vault or GUC');
    RETURN;
  END IF;

  BEGIN
    SELECT net.http_post(
      url := base_url || '/functions/v1/embed-drain',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Cron-Secret', cron_secret
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    ) INTO v_request_id;

    INSERT INTO cron_run_log (job, status, detail)
    VALUES ('embed-drain', 'ok', 'due=' || v_due ||
            ' net_request_id=' || COALESCE(v_request_id::text, 'null'));
  EXCEPTION
    WHEN invalid_schema_name OR undefined_function THEN
      INSERT INTO cron_run_log (job, status, detail)
      VALUES ('embed-drain', 'skipped', 'pg_net unavailable');
    WHEN OTHERS THEN
      INSERT INTO cron_run_log (job, status, detail)
      VALUES ('embed-drain', 'error', SQLERRM);
  END;
END;
$$;

REVOKE ALL ON FUNCTION invoke_embed_drain() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'embed-drain-every-minute';

  PERFORM cron.schedule(
    'embed-drain-every-minute',
    '* * * * *',
    $cron$ SELECT public.invoke_embed_drain(); $cron$
  );
EXCEPTION
  WHEN undefined_table OR invalid_schema_name OR undefined_function THEN
    RAISE WARNING 'pg_cron not available; skipping embed-drain schedule';
END;
$$;

-- ---------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------

INSERT INTO app_config (key, value) VALUES
  ('ai_embed_batch_limit',      '25'::jsonb),
  ('ai_embed_max_attempts',     '5'::jsonb),
  ('ai_embed_backoff_seconds',  '60'::jsonb),
  ('ai_embed_reclaim_minutes',  '10'::jsonb),
  -- Chunks below this are noise on their own and get folded into a neighbour.
  ('ai_chunk_min_tokens',       '48'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------

-- Every existing note goes through the new chunker: today's chunks were built
-- with collapsed whitespace and no title context, so they are worse than what
-- the same text produces now. Queued rather than done inline so this migration
-- stays fast and the work is rate-limited by the drainer.
--
-- 'reindex' is what keeps this free. These notes were already embedded once at
-- the user's expense, and re-chunking them is our improvement, not their
-- request; billing it would spend a free user's whole monthly allowance the
-- moment this deploys.
INSERT INTO ai_embed_queue (source_kind, source_id, reason, status)
SELECT 'node', n.id, 'reindex', 'pending'
FROM nodes n
WHERE n.deleted_at IS NULL
  AND COALESCE(n.extracted_text, '') <> ''
ON CONFLICT (source_kind, source_id) DO NOTHING;
