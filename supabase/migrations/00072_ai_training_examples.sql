-- Phase 9: one example shape, keyed by task, replacing the three v_train_*
-- shapes from 00020.
--
-- { id, task, input, context, output, signals, labels, provenance, split }
--
-- Split is derived from a hash of the row id rather than drawn at random. That
-- is what makes "assigned once and never reshuffled" true by construction: the
-- same example lands in the same split on every rebuild, in any environment, so
-- an eval set can never quietly drift into training.

SET search_path = public, extensions;

-- 80 / 10 / 10, stable for the lifetime of the row id. Two bytes of the digest
-- keep the buckets even; one byte would skew the low 56 values.
CREATE OR REPLACE FUNCTION ai_split_for(p_id text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  WITH d AS (SELECT decode(md5(p_id), 'hex') AS h)
  SELECT CASE
    WHEN (get_byte(h, 0) * 256 + get_byte(h, 1)) % 100 < 80 THEN 'train'
    WHEN (get_byte(h, 0) * 256 + get_byte(h, 1)) % 100 < 90 THEN 'validation'
    ELSE 'test'
  END
  FROM d;
$$;

-- ---------------------------------------------------------------------
-- The one shape
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW v_ai_training_examples AS
-- Everything that goes through the AI router: chat, summarise, quiz generation,
-- suggestions, question rewrites. Payload is present only with consent.
SELECT
  i.id::text                              AS id,
  i.feature                               AS task,
  i.user_id,
  i.created_at,
  COALESCE(i.payload -> 'question', i.payload -> 'input', i.payload -> 'source')
                                          AS input,
  i.payload -> 'context'                  AS context,
  COALESCE(i.payload -> 'answer', i.payload -> 'output', i.payload -> 'result')
                                          AS output,
  jsonb_strip_nulls(jsonb_build_object(
    'rating', NULLIF(i.rating, 0),
    'rating_reason', i.rating_reason,
    'had_notes', i.had_notes,
    'latency_ms', i.latency_ms,
    'input_tokens', i.input_tokens,
    'output_tokens', i.output_tokens,
    'error_code', i.error_code,
    'feedback', (
      SELECT jsonb_agg(jsonb_build_object('kind', f.kind, 'value', f.value))
      FROM ai_feedback f WHERE f.interaction_id = i.id
    )
  ))                                      AS signals,
  jsonb_strip_nulls(jsonb_build_object(
    'retrieved_node_ids', to_jsonb(i.retrieved_node_ids),
    'candidates', (
      SELECT jsonb_agg(jsonb_build_object(
        'chunk_id', c.chunk_id,
        'source_kind', c.source_kind,
        'source_id', c.source_id,
        'rank', c.rank,
        'vector_score', c.vector_score,
        'keyword_score', c.keyword_score,
        'used', c.used
      ) ORDER BY c.rank)
      FROM ai_retrieval_candidates c WHERE c.interaction_id = i.id
    )
  ))                                      AS labels,
  jsonb_strip_nulls(jsonb_build_object(
    'source_table', 'ai_interactions',
    'model', i.model,
    'provider', i.provider,
    'prompt_version', i.prompt_version,
    'system_prompt_sha', i.system_prompt_sha,
    'retrieval_mode', i.retrieval_mode,
    'scope_kind', i.scope_kind,
    'blend', i.blend,
    'request_id', i.request_id,
    'conversation_id', i.conversation_id,
    'schema_version', i.schema_version
  ))                                      AS provenance,
  ai_split_for(i.id::text)                AS split
FROM ai_interactions i
WHERE i.payload IS NOT NULL
  AND i.redacted_at IS NULL

UNION ALL

-- Note rewrites: the teacher output is the suggested markdown.
SELECT
  e.id::text,
  'evaluate',
  n.user_id,
  e.created_at,
  to_jsonb(n.markdown),
  NULL::jsonb,
  to_jsonb(e.suggested_markdown),
  jsonb_strip_nulls(jsonb_build_object(
    'quality_score', e.quality_score,
    'feedback', e.feedback
  )),
  NULL::jsonb,
  jsonb_build_object(
    'source_table', 'node_ai_evaluations',
    'model', e.model,
    'content_hash', e.content_hash
  ),
  ai_split_for(e.id::text)
FROM node_ai_evaluations e
JOIN nodes n ON n.id = e.node_id
WHERE e.suggested_markdown IS NOT NULL

UNION ALL

-- Answer grading: a real user answer with our grade is the cheapest label we
-- have for the grading task.
SELECT
  q.id::text,
  'quiz_grade',
  a.user_id,
  q.created_at,
  jsonb_build_object('question', q.question_json, 'user_answer', q.user_answer),
  NULL::jsonb,
  jsonb_strip_nulls(jsonb_build_object(
    'grade', q.grade::text,
    'is_correct', q.is_correct,
    'feedback', q.ai_feedback
  )),
  jsonb_build_object('mode', a.mode),
  NULL::jsonb,
  jsonb_build_object('source_table', 'quiz_question_attempts'),
  ai_split_for(q.id::text)
FROM quiz_question_attempts q
JOIN quiz_attempts a ON a.id = q.attempt_id
WHERE q.user_answer IS NOT NULL;

REVOKE ALL ON v_ai_training_examples FROM PUBLIC, anon, authenticated;
GRANT SELECT ON v_ai_training_examples TO service_role;

-- Superseded by the single shape above.
DROP VIEW IF EXISTS v_train_rag;
DROP VIEW IF EXISTS v_train_eval;
DROP VIEW IF EXISTS v_train_quiz;

-- ---------------------------------------------------------------------
-- Dataset build
-- ---------------------------------------------------------------------

-- An example belongs to a dataset once. Rebuilding tops up rather than
-- duplicating, and the split never moves because it comes from the id.
ALTER TABLE ai_dataset_items
  ADD COLUMN IF NOT EXISTS source_ref text;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_dataset_items_source
  ON ai_dataset_items (dataset_id, source_ref)
  WHERE source_ref IS NOT NULL;

/**
 * Materialise a task's examples into a named dataset version. Idempotent:
 * running it again adds only what is new.
 */
CREATE OR REPLACE FUNCTION ai_dataset_build(
  p_name text,
  p_task text,
  p_version text DEFAULT 'v1',
  p_since timestamptz DEFAULT NULL,
  p_limit integer DEFAULT 50000
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dataset uuid;
  v_added integer := 0;
BEGIN
  INSERT INTO ai_datasets (name, task, version)
  VALUES (p_name, p_task, COALESCE(p_version, 'v1'))
  ON CONFLICT (name, version) DO UPDATE SET task = EXCLUDED.task
  RETURNING id INTO v_dataset;

  INSERT INTO ai_dataset_items (dataset_id, example, split, source_interaction_id, source_ref)
  SELECT
    v_dataset,
    jsonb_build_object(
      'id', e.id,
      'task', e.task,
      'input', e.input,
      'context', e.context,
      'output', e.output,
      'signals', e.signals,
      'labels', e.labels,
      'provenance', e.provenance,
      'split', e.split
    ),
    e.split,
    CASE WHEN e.provenance->>'source_table' = 'ai_interactions'
         THEN e.id::uuid ELSE NULL END,
    e.id
  FROM v_ai_training_examples e
  WHERE e.task = p_task
    AND (p_since IS NULL OR e.created_at >= p_since)
    AND e.output IS NOT NULL
  ORDER BY e.created_at
  LIMIT GREATEST(COALESCE(p_limit, 50000), 1)
  ON CONFLICT (dataset_id, source_ref) WHERE source_ref IS NOT NULL
  DO NOTHING;

  GET DIAGNOSTICS v_added = ROW_COUNT;

  RETURN jsonb_build_object(
    'dataset_id', v_dataset,
    'task', p_task,
    'version', COALESCE(p_version, 'v1'),
    'added', v_added,
    'total', (SELECT count(*) FROM ai_dataset_items WHERE dataset_id = v_dataset)
  );
END;
$$;

REVOKE ALL ON FUNCTION ai_dataset_build(text, text, text, timestamptz, integer)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_dataset_build(text, text, text, timestamptz, integer)
TO service_role;

COMMENT ON VIEW v_ai_training_examples IS
  'Single training example shape keyed by task. Split is hashed from the row id so it is assigned once and never reshuffled.';
