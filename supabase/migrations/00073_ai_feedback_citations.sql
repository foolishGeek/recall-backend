-- Recall · 00073 — one citation-open label per (answer, note).
--
-- 00071 gave every feedback kind "one vote per interaction". That is right for a
-- thumb and wrong for a citation open: an answer cites several notes, and which
-- ones the reader actually opened is the relevance label the retriever learns
-- from. Collapsing them to one row threw away all but the last tap.

BEGIN;

-- Votes: still one per interaction. Events are excluded.
DROP INDEX IF EXISTS idx_ai_feedback_once;
CREATE UNIQUE INDEX idx_ai_feedback_once
  ON ai_feedback (interaction_id, kind)
  WHERE kind NOT IN ('regenerate', 'citation_opened');

-- Citation opens: one row per note opened, keyed on the node id we store in text.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_feedback_citation_once
  ON ai_feedback (interaction_id, text)
  WHERE kind = 'citation_opened';

/**
 * Record a feedback signal for one of the caller's own interactions.
 * Weak signals (citation opens, copies, abandons) are what make the retriever
 * trainable without any human labelling, so the client can write them directly.
 * For 'citation_opened', p_text carries the node id that was opened.
 */
CREATE OR REPLACE FUNCTION ai_record_feedback(
  p_interaction uuid,
  p_kind text,
  p_value smallint DEFAULT NULL,
  p_text text DEFAULT NULL,
  p_replaced uuid DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user  uuid;
  v_value smallint := LEAST(GREATEST(COALESCE(p_value, 0), -1), 1);
  v_text  text := NULLIF(btrim(COALESCE(p_text, '')), '');
BEGIN
  SELECT user_id INTO v_user
  FROM ai_interactions
  WHERE id = p_interaction AND user_id = auth.uid();

  IF v_user IS NULL THEN RETURN false; END IF;

  IF p_kind = 'citation_opened' THEN
    -- Opening the same source twice is the same label, not a stronger one.
    INSERT INTO ai_feedback (user_id, interaction_id, kind, value, text)
    VALUES (v_user, p_interaction, p_kind, v_value, v_text)
    ON CONFLICT (interaction_id, text) WHERE kind = 'citation_opened'
    DO NOTHING;
    RETURN true;
  END IF;

  INSERT INTO ai_feedback (user_id, interaction_id, kind, value, text, replaced_interaction_id)
  VALUES (v_user, p_interaction, p_kind, v_value, v_text, p_replaced)
  ON CONFLICT (interaction_id, kind) WHERE kind NOT IN ('regenerate', 'citation_opened')
  DO UPDATE SET
    value = EXCLUDED.value,
    text = COALESCE(EXCLUDED.text, ai_feedback.text),
    created_at = now();

  -- Keep the legacy column the mobile list still reads.
  IF p_kind = 'thumb' THEN
    UPDATE ai_interactions
    SET rating = v_value,
        rating_reason = v_text
    WHERE id = p_interaction;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION ai_record_feedback(uuid, text, smallint, text, uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ai_record_feedback(uuid, text, smallint, text, uuid)
TO authenticated, service_role;

/**
 * Thumbs on an interaction. The 00069 body appended a row per rating, which the
 * one-vote index in 00071 then rejected: changing a thumbs up to a thumbs down
 * raised instead of updating. Upsert, and treat clearing as removing the vote.
 */
CREATE OR REPLACE FUNCTION ai_rate_interaction(
  p_interaction uuid,
  p_rating smallint,
  p_reason text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ok boolean := false;
  v_user uuid;
  v_value smallint := LEAST(GREATEST(COALESCE(p_rating, 0), -1), 1);
  v_text text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  UPDATE ai_interactions
  SET rating = v_value,
      rating_reason = v_text
  WHERE id = p_interaction AND user_id = auth.uid()
  RETURNING user_id INTO v_user;

  GET DIAGNOSTICS ok = ROW_COUNT;
  IF NOT ok THEN RETURN false; END IF;

  IF v_value = 0 THEN
    DELETE FROM ai_feedback
    WHERE interaction_id = p_interaction AND kind = 'thumb';
  ELSE
    INSERT INTO ai_feedback (user_id, interaction_id, kind, value, text)
    VALUES (v_user, p_interaction, 'thumb', v_value, v_text)
    ON CONFLICT (interaction_id, kind)
      WHERE kind NOT IN ('regenerate', 'citation_opened')
    DO UPDATE SET
      value = EXCLUDED.value,
      text = EXCLUDED.text,
      created_at = now();
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION ai_rate_interaction(uuid, smallint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ai_rate_interaction(uuid, smallint, text)
TO authenticated, service_role;

COMMIT;
