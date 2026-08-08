-- Behavioural tests for the capture spine (00069-00072).
--
-- These cover the parts that are easy to get quietly wrong: retention actually
-- expiring text, opting out reaching data already captured, a split that never
-- moves, and asset-scoped retrieval returning asset chunks only.

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

CREATE OR REPLACE FUNCTION pgtest_vec(p_dim integer)
RETURNS vector
LANGUAGE sql AS $$
  SELECT array_agg(CASE WHEN i = p_dim THEN 1.0 ELSE 0.0 END ORDER BY i)::vector
  FROM generate_series(0, 1535) AS i;
$$;

CREATE OR REPLACE FUNCTION pgtest_capture_user(p_email text)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, confirmed_at) VALUES (uid, p_email, now());
  INSERT INTO profiles (id, ai_training_opt_in) VALUES (uid, true)
  ON CONFLICT (id) DO UPDATE SET ai_training_opt_in = true;
  RETURN uid;
END;
$$;

\echo ''
\echo '# captured text carries an expiry, and the cron drops it on time'
DO $$
DECLARE
  uid uuid := pgtest_capture_user('retain@test.local');
  iid uuid;
  keeps timestamptz;
  redacted int;
BEGIN
  iid := ai_log_interaction(
    uid, 'rag_chat', '{}'::jsonb, '{}', true, 'blended', 'test-model',
    120, 10, 20, '{"question":"q","answer":"a"}'::jsonb, NULL, true
  );

  SELECT retention_until INTO keeps FROM ai_interactions WHERE id = iid;
  PERFORM pgtest_eq(keeps IS NOT NULL, true, 'capture stamps a retention date');
  PERFORM pgtest_eq(keeps > now() + interval '700 days', true,
    'default retention is about two years');

  -- A sweep leaves anything that has not expired alone.
  PERFORM ai_redact_expired_interactions(100);
  PERFORM pgtest_eq((SELECT payload IS NOT NULL FROM ai_interactions WHERE id = iid),
    true, 'text is untouched before its expiry');

  UPDATE ai_interactions SET retention_until = now() - interval '1 day' WHERE id = iid;
  redacted := ai_redact_expired_interactions(100);
  PERFORM pgtest_eq(redacted >= 1, true, 'an expired row is redacted');

  PERFORM pgtest_eq(
    (SELECT payload IS NULL AND redacted_at IS NOT NULL FROM ai_interactions WHERE id = iid),
    true, 'redaction drops the text but keeps the row');
  PERFORM pgtest_eq(
    (SELECT input_tokens FROM ai_interactions WHERE id = iid), 10,
    'structured metrics survive redaction');
END $$;

\echo '# withdrawing training consent reaches data already captured'
DO $$
DECLARE
  uid uuid := pgtest_capture_user('optout@test.local');
  iid uuid;
BEGIN
  iid := ai_log_interaction(
    uid, 'rag_chat', '{}'::jsonb, '{}', true, 'blended', 'test-model',
    120, 10, 20, '{"question":"q","answer":"a"}'::jsonb, NULL, true
  );
  PERFORM pgtest_eq((SELECT payload IS NOT NULL FROM ai_interactions WHERE id = iid),
    true, 'opted-in capture stores the text');

  UPDATE profiles SET ai_training_opt_in = false WHERE id = uid;

  PERFORM pgtest_eq(
    (SELECT retention_until <= now() FROM ai_interactions WHERE id = iid),
    true, 'opting out expires the captured text immediately');
  PERFORM pgtest_eq(ai_redact_expired_interactions(100) >= 1, true,
    'the next sweep removes it');
END $$;

\echo '# retrieval candidates keep the near-misses'
DO $$
DECLARE
  uid uuid := pgtest_capture_user('cands@test.local');
  iid uuid;
  written int;
BEGIN
  iid := ai_log_interaction(uid, 'rag_chat');
  written := ai_log_retrieval_candidates(iid, jsonb_build_array(
    jsonb_build_object('rank', 1, 'chunk_id', gen_random_uuid(),
                       'vector_score', 0.9, 'keyword_score', 0.1, 'used', true),
    jsonb_build_object('rank', 2, 'chunk_id', gen_random_uuid(),
                       'vector_score', 0.7, 'keyword_score', 0.0, 'used', false),
    jsonb_build_object('rank', 3, 'source_kind', 'asset',
                       'source_id', gen_random_uuid(), 'used', false)
  ));

  PERFORM pgtest_eq(written, 3, 'every candidate is written, winners and losers');
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM ai_retrieval_candidates
     WHERE interaction_id = iid AND used = false), 2,
    'the rejected candidates are the training signal and are kept');
  PERFORM pgtest_eq(ai_log_retrieval_candidates(iid, '{}'::jsonb), 0,
    'a malformed payload is ignored rather than raising');
END $$;

\echo '# feedback: one vote per kind, regenerate pairs are events'
DO $$
DECLARE
  uid uuid := pgtest_capture_user('fb@test.local');
  iid uuid;
BEGIN
  iid := ai_log_interaction(uid, 'rag_chat');
  PERFORM set_config('request.jwt.claim.sub', uid::text, true);

  PERFORM pgtest_eq(ai_record_feedback(iid, 'thumb', 1::smallint), true,
    'the owner can record a thumb');
  PERFORM ai_record_feedback(iid, 'thumb', -1::smallint, 'changed my mind');
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM ai_feedback WHERE interaction_id = iid AND kind = 'thumb'),
    1, 're-voting updates instead of duplicating');
  PERFORM pgtest_eq(
    (SELECT value FROM ai_feedback WHERE interaction_id = iid AND kind = 'thumb'),
    -1::smallint, 'the latest vote wins');
  PERFORM pgtest_eq((SELECT rating FROM ai_interactions WHERE id = iid), -1::smallint,
    'the legacy rating column stays in step');

  -- Thumbs also arrive through the legacy RPC the app still calls. Flipping a
  -- vote there must update, not collide with the one-vote index.
  PERFORM ai_rate_interaction(iid, 1::smallint);
  PERFORM pgtest_eq(ai_rate_interaction(iid, -1::smallint, 'wrong'), true,
    'changing a thumbs up to a thumbs down is allowed');
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM ai_feedback WHERE interaction_id = iid AND kind = 'thumb'),
    1, 'the flipped vote replaces the old one');
  PERFORM ai_rate_interaction(iid, 0::smallint);
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM ai_feedback WHERE interaction_id = iid AND kind = 'thumb'),
    0, 'clearing the rating withdraws the vote');

  -- An answer cites several notes; which ones were opened is the whole label.
  PERFORM ai_record_feedback(iid, 'citation_opened', 1::smallint, 'node-a');
  PERFORM ai_record_feedback(iid, 'citation_opened', 1::smallint, 'node-b');
  PERFORM ai_record_feedback(iid, 'citation_opened', 1::smallint, 'node-a');
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM ai_feedback
     WHERE interaction_id = iid AND kind = 'citation_opened'),
    2, 'each opened source is its own label, re-opening is not a second one');

  PERFORM ai_record_feedback(iid, 'regenerate', NULL, NULL, NULL);
  PERFORM ai_record_feedback(iid, 'regenerate', NULL, NULL, NULL);
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM ai_feedback WHERE interaction_id = iid AND kind = 'regenerate'),
    2, 'each regenerate is its own preference pair');

  -- Someone else's interaction is invisible.
  PERFORM set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  PERFORM pgtest_eq(ai_record_feedback(iid, 'thumb', 1::smallint), false,
    'feedback on another user''s interaction is refused');
END $$;

\echo '# the train/validation/test split never moves'
DO $$
DECLARE
  id1 text := 'f0e4c2f7-6c8f-4a1b-9c3d-2b1a0e9d8c7b';
  counts record;
BEGIN
  PERFORM pgtest_eq(ai_split_for(id1), ai_split_for(id1),
    'the same id always lands in the same split');
  PERFORM pgtest_eq(ai_split_for(id1) IN ('train', 'validation', 'test'), true,
    'the split is one of the three');

  -- Roughly 80/10/10 over a decent sample; loose bounds, this is a sanity check.
  SELECT
    count(*) FILTER (WHERE s = 'train')::int AS train,
    count(*) FILTER (WHERE s = 'validation')::int AS validation,
    count(*) FILTER (WHERE s = 'test')::int AS test
  INTO counts
  FROM (SELECT ai_split_for(gen_random_uuid()::text) AS s
        FROM generate_series(1, 2000)) t;

  PERFORM pgtest_eq(counts.train BETWEEN 1500 AND 1700, true,
    'about 80% of examples are training data');
  PERFORM pgtest_eq(counts.validation BETWEEN 120 AND 280, true,
    'about 10% is held out for validation');
  PERFORM pgtest_eq(counts.test BETWEEN 120 AND 280, true,
    'about 10% is held out for test');
END $$;

\echo '# dataset build is idempotent and only takes consented text'
DO $$
DECLARE
  uid uuid := pgtest_capture_user('ds@test.local');
  iid uuid;
  first jsonb;
  again jsonb;
BEGIN
  iid := ai_log_interaction(
    uid, 'rag_chat', '{}'::jsonb, '{}', true, 'blended', 'test-model',
    120, 10, 20, '{"question":"q","answer":"a"}'::jsonb, NULL, true
  );

  first := ai_dataset_build('pgtest-chat', 'rag_chat', 'v1');
  PERFORM pgtest_eq((first->>'added')::int >= 1, true, 'the example is collected');

  again := ai_dataset_build('pgtest-chat', 'rag_chat', 'v1');
  PERFORM pgtest_eq((again->>'added')::int, 0, 'rebuilding adds nothing twice');
  PERFORM pgtest_eq((first->>'total')::int, (again->>'total')::int,
    'the dataset size is stable across rebuilds');

  -- A redacted row must not come back on the next build.
  UPDATE ai_interactions SET payload = NULL, redacted_at = now() WHERE id = iid;
  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM v_ai_training_examples WHERE id = iid::text),
    0, 'redacted interactions leave the training view');
END $$;

\echo '# asset-scoped retrieval returns attachment chunks only'
DO $$
DECLARE
  uid uuid;
  bid uuid;
  nid uuid;
  aid uuid := gen_random_uuid();
  asset_hits int;
  node_hits int;
BEGIN
  uid := pgtest_capture_user('assets@test.local');
  INSERT INTO buckets (user_id, name) VALUES (uid, 'Assets bucket') RETURNING id INTO bid;
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Lecture notes', 'Notes body about diodes.', 'ah1')
  RETURNING id INTO nid;

  INSERT INTO node_chunks (node_id, chunk_index, content, context_header, embedding,
                           source_kind, source_id, user_id)
  VALUES
    (nid, 0, 'Notes body about diodes.', 'Note', pgtest_vec(0), 'node', nid, uid),
    (nid, 1, 'Scanned slide about diodes and rectifiers.', 'Attachment',
     pgtest_vec(0), 'asset', aid, uid);

  SELECT count(*)::int INTO asset_hits
  FROM match_chunks_hybrid_v2(pgtest_vec(0), 'diodes', uid, 8, 0.1,
                              NULL, NULL, ARRAY['asset'], ARRAY[aid]);
  PERFORM pgtest_eq(asset_hits, 1, 'an asset filter returns just that attachment');

  SELECT count(*)::int INTO node_hits
  FROM match_chunks_hybrid_v2(pgtest_vec(0), 'diodes', uid, 8, 0.1,
                              NULL, NULL, ARRAY['node'], NULL);
  PERFORM pgtest_eq(node_hits, 1, 'a note-only filter excludes attachment chunks');

  PERFORM pgtest_eq(
    (SELECT count(*)::int FROM match_chunks_hybrid_v2(
       pgtest_vec(0), 'diodes', uid, 8, 0.1, ARRAY[bid], NULL, NULL, NULL)),
    2, 'with no source filter both are searchable');
END $$;

\echo '# request cost is priced from the ledger'
DO $$
DECLARE
  uid uuid := pgtest_capture_user('cost@test.local');
  rid uuid;
BEGIN
  INSERT INTO ai_requests (user_id, feature, status, model, provider,
                           input_tokens, output_tokens, reserved_at)
  VALUES (uid, 'rag_chat', 'succeeded', 'gpt-4o-mini', 'openai',
          1000000, 1000000, now())
  RETURNING id INTO rid;

  -- 1M input at 0.15 + 1M output at 0.60 = 0.75
  PERFORM pgtest_eq((SELECT cost FROM v_ai_request_cost WHERE id = rid),
    0.750000::numeric, 'a priced model yields cost in currency');

  UPDATE ai_requests SET model = 'not-a-model' WHERE id = rid;
  PERFORM pgtest_eq((SELECT cost IS NULL FROM v_ai_request_cost WHERE id = rid),
    true, 'an unpriced model reports no cost rather than zero');
END $$;
