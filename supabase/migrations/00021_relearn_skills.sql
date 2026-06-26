-- Sprint: Aura AI engine — re-learning weak skills [D-AI-9]. Surfaces nodes the
-- user is weak on (recent quiz again/hard, lapses, low comfort, relearning) so
-- the app can offer a focused re-learn session. We REUSE the existing engine —
-- grading still flows through record_review_rpc; this only ranks/selects nodes.
-- Builds on the canonical v_weak_topics (comfort<40, difficulty>=4).
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md.

SET search_path = public, extensions;

CREATE OR REPLACE VIEW v_relearn_skills WITH (security_invoker = true) AS
WITH recent_q AS (
  SELECT qqa.node_id,
         count(*) FILTER (WHERE qqa.grade IN ('again', 'hard')) AS weak_grades,
         max(qqa.answered_at) AS last_quiz_at
  FROM quiz_question_attempts qqa
  JOIN quiz_attempts qa ON qa.id = qqa.attempt_id
  WHERE qqa.node_id IS NOT NULL
    AND qqa.answered_at >= now() - interval '30 days'
  GROUP BY qqa.node_id
)
SELECT
  b.user_id,
  n.id   AS node_id,
  n.title,
  b.id   AS bucket_id,
  b.name AS bucket_name,
  n.comfort,
  n.difficulty,
  n.lapses,
  n.state,
  n.due_at,
  COALESCE(rq.weak_grades, 0) AS recent_weak_grades,
  rq.last_quiz_at,
  (
    GREATEST(0, 100 - COALESCE(n.comfort, 50))::numeric
    + COALESCE(n.lapses, 0) * 10
    + COALESCE(rq.weak_grades, 0) * 15
    + CASE WHEN n.state = 'relearning' THEN 20 ELSE 0 END
  ) AS weakness_score
FROM nodes n
JOIN buckets b ON b.id = n.bucket_id
LEFT JOIN recent_q rq ON rq.node_id = n.id
WHERE n.deleted_at IS NULL AND b.deleted_at IS NULL
  AND (
    (n.comfort < 40 AND n.difficulty >= 4)
    OR COALESCE(rq.weak_grades, 0) > 0
    OR COALESCE(n.lapses, 0) > 0
    OR n.state = 'relearning'
  );

GRANT SELECT ON v_relearn_skills TO authenticated;

-- Returns the top weak node ids for the current user (optionally scoped to
-- buckets) to seed a focused review stack or a by_node quiz.
CREATE OR REPLACE FUNCTION build_relearn_session(
  p_limit int DEFAULT 20,
  p_bucket_ids uuid[] DEFAULT NULL
) RETURNS uuid[]
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(array_agg(node_id ORDER BY weakness_score DESC), '{}')
  FROM (
    SELECT node_id, weakness_score
    FROM v_relearn_skills
    WHERE user_id = auth.uid()
      AND (p_bucket_ids IS NULL OR bucket_id = ANY(p_bucket_ids))
    ORDER BY weakness_score DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100))
  ) t;
$$;

REVOKE ALL ON FUNCTION build_relearn_session(int, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION build_relearn_session(int, uuid[]) TO authenticated, service_role;
