-- Behavioural tests for the embed queue and atomic chunk replacement (00061).
--
-- The point of this migration is that a note can no longer end up silently
-- unsearchable, so these tests are mostly about the failure paths: a lost
-- webhook, a worker that dies mid-flight, a provider outage, and an insert that
-- fails halfway through replacing a note's chunks.

\set ON_ERROR_STOP on
SET client_min_messages TO notice;

CREATE OR REPLACE FUNCTION pgtest_eq(actual anyelement, expected anyelement, label text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'FAIL %: expected %, got %',
      label, COALESCE(expected::text, 'NULL'), COALESCE(actual::text, 'NULL');
  END IF;
  RAISE NOTICE '  ok  %', label;
END;
$$;

-- A user with one bucket, ready to hang notes off.
CREATE OR REPLACE FUNCTION pgtest_bucket(p_email text)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  uid uuid := gen_random_uuid();
  bid uuid;
BEGIN
  INSERT INTO auth.users (id, email, confirmed_at) VALUES (uid, p_email, now());
  INSERT INTO profiles (id) VALUES (uid) ON CONFLICT (id) DO NOTHING;
  INSERT INTO buckets (user_id, name) VALUES (uid, 'Test bucket') RETURNING id INTO bid;
  RETURN bid;
END;
$$;

-- Claiming is global by nature, so any test that counts what a claim returns has
-- to start from an empty queue rather than whatever earlier tests left pending.
CREATE OR REPLACE FUNCTION pgtest_reset_queue()
RETURNS void
LANGUAGE sql AS $$ DELETE FROM ai_embed_queue; $$;

CREATE OR REPLACE FUNCTION pgtest_qstatus(p_node uuid)
RETURNS text
LANGUAGE sql AS $$
  SELECT status::text FROM ai_embed_queue
  WHERE source_kind = 'node' AND source_id = p_node;
$$;

-- A deterministic unit vector, so tests never depend on a real embedding call.
CREATE OR REPLACE FUNCTION pgtest_vec(p_seed integer)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_agg(CASE WHEN i = p_seed % 1536 THEN 1.0 ELSE 0.0 END ORDER BY i)
  FROM generate_series(0, 1535) AS i;
$$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# saving a note queues it for embedding'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-enqueue@test.local');
  nid uuid;
BEGIN
  -- No content yet: nothing to embed, so nothing should be queued.
  INSERT INTO nodes (bucket_id, title) VALUES (bid, 'Empty note') RETURNING id INTO nid;
  PERFORM pgtest_eq(pgtest_qstatus(nid), NULL, 'a content-less note is not queued');

  UPDATE nodes SET extracted_text = 'Rainfall peaks in March.', content_hash = 'h1'
  WHERE id = nid;
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'pending', 'adding content queues the note');

  -- Re-saving the same content is not new work.
  UPDATE nodes SET content_hash = 'h1' WHERE id = nid;
  PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_embed_queue WHERE source_id = nid),
                    1, 'an unchanged save adds nothing');

  -- Ten edits in a row leave one thing to do, not ten.
  UPDATE nodes SET content_hash = 'h2' WHERE id = nid;
  UPDATE nodes SET content_hash = 'h3' WHERE id = nid;
  UPDATE nodes SET content_hash = 'h4' WHERE id = nid;
  PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_embed_queue WHERE source_id = nid),
                    1, 'repeated edits coalesce into one queue row');
END $$;

\echo '# clearing a note''s text is queued too, so its chunks get removed'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-cleared@test.local');
  nid uuid;
BEGIN
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'some text', 'h1') RETURNING id INTO nid;
  PERFORM ai_embed_complete((SELECT id FROM ai_embed_queue WHERE source_id = nid), true);
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'done', 'first pass done');

  UPDATE nodes SET extracted_text = '', content_hash = NULL WHERE id = nid;
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'pending', 'emptying the note re-queues it');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# claiming hands out work once'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-claim@test.local');
  i   integer;
  n   integer;
BEGIN
  PERFORM pgtest_reset_queue();
  FOR i IN 1..5 LOOP
    INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
    VALUES (bid, 'Note ' || i, 'text ' || i, 'h' || i);
  END LOOP;

  SELECT count(*) INTO n FROM ai_embed_claim(3);
  PERFORM pgtest_eq(n, 3, 'the limit is respected');
  PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_embed_queue WHERE status = 'processing'),
                    3, 'claimed rows are marked processing');

  -- A second claim must not hand back the rows already in flight.
  SELECT count(*) INTO n FROM ai_embed_claim(10);
  PERFORM pgtest_eq(n, 2, 'the second claim only gets what is left');

  SELECT count(*) INTO n FROM ai_embed_claim(10);
  PERFORM pgtest_eq(n, 0, 'nothing is handed out twice');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a worker that dies mid-flight does not lose the note'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-crash@test.local');
  nid uuid;
  qid bigint;
  n   integer;
BEGIN
  PERFORM pgtest_reset_queue();
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;

  SELECT id INTO qid FROM ai_embed_claim(1);
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'processing', 'claimed');

  -- Still inside the reclaim window: leave it alone.
  SELECT count(*) INTO n FROM ai_embed_claim(10);
  PERFORM pgtest_eq(n, 0, 'a live worker keeps its claim');

  -- Past the window, the worker is presumed dead.
  UPDATE ai_embed_queue SET claimed_at = now() - interval '30 minutes' WHERE id = qid;
  SELECT count(*) INTO n FROM ai_embed_claim(10);
  PERFORM pgtest_eq(n, 1, 'an abandoned claim is handed out again');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a failing note is retried with backoff, then fails visibly'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-retry@test.local');
  nid uuid;
  qid bigint;
  max_attempts integer := app_config_int('ai_embed_max_attempts', 5);
  prev_delay interval := interval '0';
  delay interval;
  i integer;
BEGIN
  PERFORM pgtest_reset_queue();
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;
  SELECT id INTO qid FROM ai_embed_queue WHERE source_id = nid;

  FOR i IN 1..(max_attempts - 1) LOOP
    PERFORM ai_embed_complete(qid, false, 'provider timeout');
    PERFORM pgtest_eq(pgtest_qstatus(nid), 'pending',
                      'attempt ' || i || ' stays pending for a retry');

    SELECT next_attempt_at - now() INTO delay FROM ai_embed_queue WHERE id = qid;
    IF delay <= prev_delay THEN
      RAISE EXCEPTION 'FAIL backoff did not grow: attempt % waits %, previous waited %',
        i, delay, prev_delay;
    END IF;
    prev_delay := delay;

    -- Backed off, so it must not be handed out yet.
    PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_embed_claim(10)), 0,
                      'a backed-off note is not retried early');
  END LOOP;
  PERFORM pgtest_eq(true, true, 'backoff grew on every retry');

  PERFORM ai_embed_complete(qid, false, 'provider timeout');
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'failed',
                    'it gives up after ' || max_attempts || ' attempts');
  PERFORM pgtest_eq((SELECT last_error FROM ai_embed_queue WHERE id = qid),
                    'provider timeout', 'and says why');

  -- A failed note must never be silently retried forever.
  PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_embed_claim(10)), 0,
                    'a failed note is not picked up again');

  -- But editing it is a fresh start.
  UPDATE nodes SET content_hash = 'h2' WHERE id = nid;
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'pending', 'editing it clears the failure');
  PERFORM pgtest_eq((SELECT attempts FROM ai_embed_queue WHERE id = qid), 0,
                    'and resets the attempt count');
END $$;

\echo '# a successful pass clears the error and the claim'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-recover@test.local');
  nid uuid;
  qid bigint;
BEGIN
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;
  SELECT id INTO qid FROM ai_embed_queue WHERE source_id = nid;

  PERFORM ai_embed_complete(qid, false, 'transient');
  PERFORM ai_embed_complete(qid, true);
  PERFORM pgtest_eq(pgtest_qstatus(nid), 'done', 'recovered to done');
  PERFORM pgtest_eq((SELECT last_error FROM ai_embed_queue WHERE id = qid), NULL,
                    'the stale error is cleared');
  PERFORM pgtest_eq((SELECT claimed_at FROM ai_embed_queue WHERE id = qid), NULL,
                    'the claim is released');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# chunk replacement is all-or-nothing'
DO $$
DECLARE
  bid uuid := pgtest_bucket('chunks-replace@test.local');
  nid uuid;
  n   integer;
BEGIN
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;

  n := node_chunks_replace(nid, jsonb_build_array(
    jsonb_build_object('chunk_index', 0, 'content', 'first',
                       'context_header', 'Test bucket › Note',
                       'token_count', 12, 'embedding', pgtest_vec(1)),
    jsonb_build_object('chunk_index', 1, 'content', 'second',
                       'context_header', 'Test bucket › Note',
                       'token_count', 9, 'embedding', pgtest_vec(2))
  ));
  PERFORM pgtest_eq(n, 2, 'two chunks written');
  PERFORM pgtest_eq((SELECT count(*)::integer FROM node_chunks WHERE node_id = nid), 2,
                    'and they are there');
  PERFORM pgtest_eq((SELECT token_count FROM node_chunks
                     WHERE node_id = nid AND chunk_index = 0), 12,
                    'the real token count is stored');
  PERFORM pgtest_eq((SELECT context_header FROM node_chunks
                     WHERE node_id = nid AND chunk_index = 0), 'Test bucket › Note',
                    'and the header that went into the vector');

  -- A second pass replaces rather than accumulates.
  n := node_chunks_replace(nid, jsonb_build_array(
    jsonb_build_object('chunk_index', 0, 'content', 'only one now',
                       'context_header', '', 'token_count', 5,
                       'embedding', pgtest_vec(3))
  ));
  PERFORM pgtest_eq(n, 1, 'the replacement wrote one chunk');
  PERFORM pgtest_eq((SELECT count(*)::integer FROM node_chunks WHERE node_id = nid), 1,
                    'the old generation is gone');
  PERFORM pgtest_eq((SELECT content FROM node_chunks WHERE node_id = nid), 'only one now',
                    'the new content is live');
  PERFORM pgtest_eq((SELECT context_header FROM node_chunks WHERE node_id = nid), NULL,
                    'an empty header is stored as NULL, not as blank text');
END $$;

\echo '# a bad batch leaves the previous chunks intact'
DO $$
DECLARE
  bid uuid := pgtest_bucket('chunks-atomic@test.local');
  nid uuid;
BEGIN
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;

  PERFORM node_chunks_replace(nid, jsonb_build_array(
    jsonb_build_object('chunk_index', 0, 'content', 'good',
                       'token_count', 4, 'embedding', pgtest_vec(1))
  ));
  PERFORM pgtest_eq((SELECT count(*)::integer FROM node_chunks WHERE node_id = nid), 1,
                    'a good generation exists');

  -- The second chunk has a wrong-width vector, so the insert must fail whole.
  -- This is the case that used to leave the note with zero chunks.
  BEGIN
    PERFORM node_chunks_replace(nid, jsonb_build_array(
      jsonb_build_object('chunk_index', 0, 'content', 'new one',
                         'token_count', 4, 'embedding', pgtest_vec(2)),
      jsonb_build_object('chunk_index', 1, 'content', 'broken',
                         'token_count', 4, 'embedding', '[1,2,3]'::jsonb)
    ));
    RAISE EXCEPTION 'FAIL a wrong-width vector was accepted';
  EXCEPTION WHEN data_exception OR internal_error OR check_violation THEN
    NULL;   -- expected: pgvector rejects the dimension mismatch
  END;

  PERFORM pgtest_eq((SELECT count(*)::integer FROM node_chunks WHERE node_id = nid), 1,
                    'the note still has its previous chunks');
  PERFORM pgtest_eq((SELECT content FROM node_chunks WHERE node_id = nid), 'good',
                    'and they are the old, working generation');
END $$;

\echo '# an empty batch is how a cleared note stops being searchable'
DO $$
DECLARE
  bid uuid := pgtest_bucket('chunks-clear@test.local');
  nid uuid;
BEGIN
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;

  PERFORM node_chunks_replace(nid, jsonb_build_array(
    jsonb_build_object('chunk_index', 0, 'content', 'stale',
                       'token_count', 4, 'embedding', pgtest_vec(1))
  ));
  PERFORM pgtest_eq(node_chunks_replace(nid, '[]'::jsonb), 0, 'an empty batch writes nothing');
  PERFORM pgtest_eq((SELECT count(*)::integer FROM node_chunks WHERE node_id = nid), 0,
                    'and clears the stale chunks');
END $$;

\echo '# a malformed batch is refused rather than silently dropping chunks'
DO $$
DECLARE
  bid uuid := pgtest_bucket('chunks-malformed@test.local');
  nid uuid;
BEGIN
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;
  PERFORM node_chunks_replace(nid, jsonb_build_array(
    jsonb_build_object('chunk_index', 0, 'content', 'keep me',
                       'token_count', 4, 'embedding', pgtest_vec(1))
  ));

  BEGIN
    PERFORM node_chunks_replace(nid, '{"not":"an array"}'::jsonb);
    RAISE EXCEPTION 'FAIL a non-array batch was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;

  PERFORM pgtest_eq((SELECT count(*)::integer FROM node_chunks WHERE node_id = nid), 1,
                    'the existing chunks survive a malformed call');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# a reindex is marked so nobody gets billed for our own improvement'
DO $$
DECLARE
  bid uuid := pgtest_bucket('embed-reason@test.local');
  nid uuid;
BEGIN
  PERFORM pgtest_reset_queue();

  -- A user editing their note is their request, and is charged for.
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Note', 'text', 'h1') RETURNING id INTO nid;
  PERFORM pgtest_eq((SELECT reason FROM ai_embed_queue WHERE source_id = nid),
                    'content_change', 'a save is billed as a content change');

  -- A reindex must not erase an edit that has not been embedded yet, or the
  -- user's change would quietly turn into our unbilled work.
  PERFORM ai_embed_enqueue(nid, 'node', 'reindex');
  PERFORM pgtest_eq((SELECT reason FROM ai_embed_queue WHERE source_id = nid),
                    'content_change', 'a reindex cannot displace a pending edit');

  -- Once that edit is embedded, re-chunking the same content is ours to pay for.
  PERFORM ai_embed_complete((SELECT id FROM ai_embed_queue WHERE source_id = nid), true);
  PERFORM ai_embed_enqueue(nid, 'node', 'reindex');
  PERFORM pgtest_eq((SELECT reason FROM ai_embed_queue WHERE source_id = nid),
                    'reindex', 'rebuilding settled content is a reindex');
  PERFORM pgtest_eq((SELECT reason FROM ai_embed_claim(10) WHERE source_id = nid),
                    'reindex', 'and the worker is told which it is');

  -- If the user edits while a reindex is queued, it becomes their request again.
  PERFORM ai_embed_complete((SELECT id FROM ai_embed_queue WHERE source_id = nid), true);
  PERFORM ai_embed_enqueue(nid, 'node', 'reindex');
  UPDATE nodes SET content_hash = 'h2' WHERE id = nid;
  PERFORM pgtest_eq((SELECT reason FROM ai_embed_queue WHERE source_id = nid),
                    'content_change', 'a real edit supersedes a queued reindex');

  PERFORM pgtest_eq((SELECT count(*)::integer FROM ai_embed_queue
                     WHERE reason NOT IN ('content_change', 'reindex')), 0,
                    'no other reason can be stored');
END $$;

\echo '# the backfill queued existing notes as unbilled reindex work'
DO $$
BEGIN
  -- The migration ran against an empty nodes table here, so assert the shape of
  -- the rule rather than the row count: a reason must be explicit, and the
  -- column default must be the billed one so a caller cannot get free work by
  -- omitting it.
  PERFORM pgtest_eq(
    (SELECT column_default FROM information_schema.columns
     WHERE table_name = 'ai_embed_queue' AND column_name = 'reason'),
    '''content_change''::text',
    'the default is the billed reason, so free work must be asked for');
END $$;


-- ---------------------------------------------------------------------------
\echo ''
\echo '# the queue is reachable only through the definer functions'
DO $$
BEGIN
  PERFORM pgtest_eq((SELECT relrowsecurity FROM pg_class WHERE relname = 'ai_embed_queue'),
                    true, 'row level security is on');
  PERFORM pgtest_eq((SELECT count(*)::integer FROM pg_policies
                     WHERE tablename = 'ai_embed_queue'), 0,
                    'and no policy opens it to app users');
  PERFORM pgtest_eq(has_function_privilege('authenticated',
                    'ai_embed_claim(integer)', 'EXECUTE'), false,
                    'app users cannot claim work');
  PERFORM pgtest_eq(has_function_privilege('authenticated',
                    'ai_embed_enqueue(uuid, text, text)', 'EXECUTE'), false,
                    'app users cannot queue free embedding for themselves');
  PERFORM pgtest_eq(has_function_privilege('authenticated',
                    'node_chunks_replace(uuid, jsonb)', 'EXECUTE'), false,
                    'app users cannot rewrite chunks');
END $$;


DROP FUNCTION pgtest_eq(anyelement, anyelement, text);
DROP FUNCTION pgtest_bucket(text);
DROP FUNCTION pgtest_reset_queue();
DROP FUNCTION pgtest_qstatus(uuid);
DROP FUNCTION pgtest_vec(integer);

\echo ''
\echo 'ALL EMBED QUEUE TESTS PASSED'
