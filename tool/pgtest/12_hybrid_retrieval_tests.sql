-- Behavioural tests for hybrid retrieval (00062).
-- Keyword search must find proper nouns that a pure vector query misses.

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

CREATE OR REPLACE FUNCTION pgtest_vec(p_dim integer)
RETURNS vector
LANGUAGE sql AS $$
  SELECT array_agg(CASE WHEN i = p_dim THEN 1.0 ELSE 0.0 END ORDER BY i)::vector
  FROM generate_series(0, 1535) AS i;
$$;

\echo ''
\echo '# hybrid match finds a keyword the vector channel would miss'
DO $$
DECLARE
  bid uuid := pgtest_bucket('hybrid@test.local');
  uid uuid;
  nid1 uuid;
  nid2 uuid;
  keyword_hits int;
  wrapper_hits int;
  null_tsv int;
BEGIN
  SELECT user_id INTO uid FROM buckets WHERE id = bid;

  -- match_chunks_hybrid authorises via auth.uid() or service_role. Local tests
  -- run as the postgres role, so pretend to be the service role.
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Binary arithmetic', 'Adding bits with carry.', 'h1')
  RETURNING id INTO nid1;
  INSERT INTO nodes (bucket_id, title, extracted_text, content_hash)
  VALUES (bid, 'Karnaugh maps', 'Simplifying boolean expressions with Karnaugh maps.', 'h2')
  RETURNING id INTO nid2;

  -- Orthogonal embeddings: note1 near dim 0, note2 near dim 1.
  INSERT INTO node_chunks (node_id, chunk_index, content, context_header, embedding)
  VALUES
    (nid1, 0, 'Adding bits with carry and overflow.',
     'Note: Binary arithmetic', pgtest_vec(0)),
    (nid1, 1, 'Two''s complement negation.',
     'Note: Binary arithmetic', pgtest_vec(0)),
    (nid2, 0, 'Simplifying boolean expressions with Karnaugh maps.',
     'Note: Karnaugh maps', pgtest_vec(1));

  -- Query vector points at note1, but the text asks for Karnaugh.
  SELECT count(*)::int INTO keyword_hits
  FROM match_chunks_hybrid(
    pgtest_vec(0),
    'Karnaugh',
    uid,
    8,
    0.1,
    ARRAY[bid],
    NULL
  ) h
  WHERE h.content ILIKE '%Karnaugh%';

  PERFORM pgtest_eq(keyword_hits >= 1, true,
    'keyword channel surfaces the Karnaugh chunk');

  -- Legacy wrapper still returns vector hits.
  SELECT count(*)::int INTO wrapper_hits
  FROM match_chunks(pgtest_vec(0), uid, 8, 0.1, ARRAY[bid], NULL);
  PERFORM pgtest_eq(wrapper_hits >= 1, true, 'match_chunks wrapper still works');

  SELECT count(*)::int INTO null_tsv FROM node_chunks WHERE content_tsv IS NULL;
  PERFORM pgtest_eq(null_tsv, 0, 'every chunk has a content_tsv');
END $$;

\echo '# config seeds for retrieval knobs are present'
DO $$
BEGIN
  PERFORM pgtest_eq(
    (SELECT value #>> '{}' FROM app_config WHERE key = 'ai_max_chunks_per_node'),
    '3', 'ai_max_chunks_per_node seeded');
  PERFORM pgtest_eq(
    (SELECT value #>> '{}' FROM app_config WHERE key = 'ai_rag_retrieve_k'),
    '24', 'ai_rag_retrieve_k seeded');
  PERFORM pgtest_eq(
    (SELECT (value #>> '{}')::numeric < 0.7 FROM app_config
     WHERE key = 'ai_rag_similarity_threshold'),
    true, 'global similarity threshold retuned below 0.7');
END $$;
