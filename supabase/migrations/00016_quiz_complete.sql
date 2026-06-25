-- Sprint 19 · Quiz completion (server-authoritative).
-- Grades the attempt, runs the recall engine per node-backed question via the
-- single authoritative `record_review_rpc` write path (source=quiz), finalizes
-- the attempt, awards +15 XP + quiz_ace once, and returns the results payload
-- consumed by modules/quiz_results [D-EF-3]. Also builds a review-missed stack
-- from explicit node ids for the "Review missed cards" CTA.
-- Idempotent + replay-safe: reviews dedupe on idempotency_key; XP/finalization
-- only fire on the in_progress -> completed transition. Tie-breaker: CANON-DECISIONS.md.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- quiz_complete_rpc — EF-only (service role). The caller (quiz-complete EF)
-- has already verified ownership + premium and resolved any pending AI grades.
-- p_user is set as the auth subject for the duration of the call so the reused
-- record_review_rpc + its gamification triggers attribute writes correctly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION quiz_complete_rpc(p_user uuid, p_attempt_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a_row quiz_attempts%ROWTYPE;
  total integer;
  correct integer;
  v_score numeric(5,2);
  xp_awarded integer := 0;
  was_completed boolean := false;
  qa record;
  rev jsonb;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO a_row FROM quiz_attempts WHERE id = p_attempt_id FOR UPDATE;
  IF NOT FOUND OR a_row.user_id <> p_user THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  was_completed := (a_row.status = 'completed');

  -- Attribute reused record_review_rpc writes (and its triggers) to p_user by
  -- setting the auth subject for this transaction. Both claim styles are set so
  -- auth.uid() resolves whichever form this project's helper reads.
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text)::text, true);

  IF NOT was_completed THEN
    -- 1) Grade everything not yet graded as a skip / lapse (again) [D-ENG-6].
    --    Catches unanswered questions and short answers left pending by S18.
    UPDATE quiz_question_attempts
    SET grade = 'again'::review_grade,
        is_correct = false,
        answered_at = COALESCE(answered_at, now())
    WHERE attempt_id = p_attempt_id
      AND grade IS NULL;

    -- 2) Engine write per node-backed question, in order. Free-hand questions
    --    (node_id NULL) are excluded from engine writes [09a]. Idempotency key
    --    quiz:{attempt}:{question} makes re-calling safe (no double reviews/XP).
    FOR qa IN
      SELECT id, node_id, grade, response_ms
      FROM quiz_question_attempts
      WHERE attempt_id = p_attempt_id
        AND node_id IS NOT NULL
      ORDER BY position
    LOOP
      -- Guard each engine write: a node deleted/unowned since play must not
      -- abort the whole completion. The savepoint rolls back only that write.
      BEGIN
        rev := record_review_rpc(jsonb_build_object(
          'node_id', qa.node_id,
          'quiz_attempt_id', p_attempt_id,
          'source', 'quiz',
          'grade', COALESCE(qa.grade::text, 'again'),
          'response_ms', COALESCE(qa.response_ms, 0),
          'idempotency_key', 'quiz:' || p_attempt_id::text || ':' || qa.id::text
        ));

        -- Mirror the post-review comfort onto the question attempt row.
        UPDATE quiz_question_attempts
        SET comfort_after = NULLIF(rev->'node'->>'comfort', '')::smallint
        WHERE id = qa.id;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END LOOP;
  END IF;

  -- 3) Score: skipped count as incorrect; total = question_count [D-ENG-6].
  SELECT count(*) FILTER (WHERE is_correct), count(*)
    INTO correct, total
  FROM quiz_question_attempts
  WHERE attempt_id = p_attempt_id;

  total := COALESCE(NULLIF(a_row.question_count, 0), total, 0);
  v_score := CASE WHEN total = 0 THEN 0
                  ELSE round(100.0 * COALESCE(correct, 0) / total, 1) END;

  -- 4) Finalize the attempt + quiz bonus once (in_progress -> completed).
  IF NOT was_completed THEN
    UPDATE quiz_attempts
    SET status = 'completed', completed_at = now(), score_pct = v_score
    WHERE id = p_attempt_id;

    UPDATE profiles
    SET xp = xp + 15, level = level_for_xp(xp + 15)
    WHERE id = p_user;
    xp_awarded := 15;

    IF v_score = 100 THEN
      PERFORM unlock_achievement(p_user, 'quiz_ace');
    END IF;
  END IF;

  -- 5) Assemble the results payload [D-EF-3].
  RETURN jsonb_build_object(
    'score_pct', v_score,
    'total', total,
    'correct', COALESCE(correct, 0),
    'xp_awarded', xp_awarded,
    -- Header scope: the single bucket name when the attempt is one bucket, else null.
    'scope_label', (
      SELECT CASE WHEN count(DISTINCT b.name) = 1 THEN min(b.name) ELSE NULL END
      FROM quiz_question_attempts q
      JOIN buckets b ON b.id = q.bucket_id
      WHERE q.attempt_id = p_attempt_id AND q.bucket_id IS NOT NULL
    ),
    'questions', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'question_attempt_id', q.id,
        'prompt', q.question_json->>'prompt',
        'is_correct', COALESCE(q.is_correct, false),
        'user_answer', q.user_answer,
        'correct_answer', CASE q.question_json->>'type'
            WHEN 'mcq' THEN (q.question_json->'options') ->> (NULLIF(q.question_json->>'correct_index','')::int)
            WHEN 'short_answer' THEN q.question_json->>'reference_answer'
            WHEN 'flashcard' THEN q.question_json->>'flashcard_back'
            ELSE NULL END,
        'ai_feedback', q.ai_feedback,
        'grade', q.grade::text,
        'node_id', q.node_id,
        'node_title', n.title
      ) ORDER BY q.position), '[]'::jsonb)
      FROM quiz_question_attempts q
      LEFT JOIN nodes n ON n.id = q.node_id
      WHERE q.attempt_id = p_attempt_id
    ),
    -- Weak topics consume the canonical v_weak_topics definition (comfort<40,
    -- difficulty>=4) so this never drifts from the rest of the app [D-EF-3].
    'weak_topics', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'node_id', d.node_id, 'title', d.title, 'bucket_name', d.bucket_name,
        'comfort', d.comfort, 'priority', d.priority, 'difficulty', d.difficulty
      ) ORDER BY d.comfort ASC), '[]'::jsonb)
      FROM (
        SELECT DISTINCT w.node_id, w.title, w.bucket_name,
               w.comfort, w.priority, w.difficulty
        FROM quiz_question_attempts q
        JOIN v_weak_topics w ON w.node_id = q.node_id
        WHERE q.attempt_id = p_attempt_id
      ) d
    ),
    'comfort_updates', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'node_id', cu.node_id, 'title', n.title,
        'comfort_before', cu.comfort_before, 'comfort_after', cu.comfort_after,
        'grade', cu.grade::text
      ) ORDER BY n.title), '[]'::jsonb)
      FROM (
        SELECT r.node_id,
          (array_agg(r.comfort_before ORDER BY r.reviewed_at ASC, r.created_at ASC))[1] AS comfort_before,
          (array_agg(r.comfort_after  ORDER BY r.reviewed_at DESC, r.created_at DESC))[1] AS comfort_after,
          (array_agg(r.grade          ORDER BY r.reviewed_at DESC, r.created_at DESC))[1] AS grade
        FROM reviews r
        WHERE r.quiz_attempt_id = p_attempt_id
        GROUP BY r.node_id
      ) cu
      JOIN nodes n ON n.id = cu.node_id
    ),
    'review_missed_node_ids', (
      SELECT COALESCE(jsonb_agg(DISTINCT q.node_id), '[]'::jsonb)
      FROM quiz_question_attempts q
      WHERE q.attempt_id = p_attempt_id
        AND q.node_id IS NOT NULL
        AND COALESCE(q.is_correct, false) = false
    )
  );
END;
$$;

-- ---------------------------------------------------------------------
-- build_stack_from_nodes_rpc — authenticated. Creates an active stack from the
-- explicit missed node ids (preserving caller order) for the "Review missed
-- cards" CTA. Honors the single-active-stack invariant (returns the existing
-- active stack if one is already open) and the free_tier_stack_limit trigger.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION build_stack_from_nodes_rpc(p_node_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p_user uuid := auth.uid();
  sp scheduling_params%ROWTYPE;
  active_stack stacks%ROWTYPE;
  new_stack stacks%ROWTYPE;
  v_now timestamptz := now();
  sel_count integer;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT s.* INTO active_stack
  FROM stacks s
  WHERE s.user_id = p_user AND s.status = 'active'
  LIMIT 1;

  IF active_stack.id IS NOT NULL THEN
    RETURN stack_payload_json(active_stack.id) || jsonb_build_object('existing', true);
  END IF;

  IF p_node_ids IS NULL OR array_length(p_node_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('stack', NULL, 'items', '[]'::jsonb, 'reason', 'empty_pool');
  END IF;

  SELECT * INTO sp FROM engine_params(p_user, NULL);
  IF sp.id IS NULL THEN
    RAISE EXCEPTION 'invalid_input: scheduling_params missing' USING ERRCODE = '22023';
  END IF;

  DROP TABLE IF EXISTS pg_temp.tmp_missed_nodes;
  CREATE TEMP TABLE tmp_missed_nodes ON COMMIT DROP AS
  WITH input AS (
    SELECT id, ord FROM unnest(p_node_ids) WITH ORDINALITY AS u(id, ord)
  ),
  owned AS (
    SELECT DISTINCT ON (n.id)
           n.id AS node_id,
           i.ord,
           engine_heat(n.stability, n.last_reviewed_at, n.due_at, n.priority, n.difficulty, sp.target_retention, v_now) AS heat_value
    FROM input i
    JOIN nodes n ON n.id = i.id
    JOIN buckets b ON b.id = n.bucket_id
    WHERE b.user_id = p_user
      AND n.deleted_at IS NULL
      AND b.deleted_at IS NULL
      AND n.state <> 'leech'::node_state
    ORDER BY n.id, i.ord
  )
  SELECT node_id,
         (row_number() OVER (ORDER BY ord) - 1)::smallint AS position,
         heat_value
  FROM owned;

  SELECT count(*) INTO sel_count FROM tmp_missed_nodes;
  IF sel_count = 0 THEN
    RETURN jsonb_build_object('stack', NULL, 'items', '[]'::jsonb, 'reason', 'empty_pool');
  END IF;

  INSERT INTO stacks (user_id, scope)
  VALUES (p_user, jsonb_build_object('source', 'quiz_missed'))
  RETURNING * INTO new_stack;

  INSERT INTO stack_items (stack_id, node_id, position, heat_snapshot)
  SELECT new_stack.id, node_id, position, heat_value
  FROM tmp_missed_nodes
  ORDER BY position;

  RETURN stack_payload_json(new_stack.id) || jsonb_build_object('existing', false);
END;
$$;

-- ---------------------------------------------------------------------
-- Privileges. quiz_complete_rpc is service-role only (the EF orchestrates auth
-- + premium + AI resolution). build_stack_from_nodes_rpc is a normal user RPC.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION quiz_complete_rpc(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION quiz_complete_rpc(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION build_stack_from_nodes_rpc(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION build_stack_from_nodes_rpc(uuid[]) TO authenticated;
