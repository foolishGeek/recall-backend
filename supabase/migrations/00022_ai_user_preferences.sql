-- Sprint: Aura AI engine — per-user personalization [D-AI-8]. Feedback tunes
-- Aura for THAT user only via lightweight style directives injected into their
-- prompts. No global prompt changes (predictable + robust). Suggestions are
-- always acknowledged; we map common phrasings to directives and keep the raw
-- text. Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS ai_user_preferences (
  user_id          uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  style_directives jsonb NOT NULL DEFAULT '{}'::jsonb,  -- {length, examples, depth, tone, format}
  custom_notes     text[] NOT NULL DEFAULT '{}',
  updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE ai_user_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_user_preferences_owner_select ON ai_user_preferences;
CREATE POLICY ai_user_preferences_owner_select ON ai_user_preferences
  FOR SELECT USING (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- ai_apply_suggestion: map a free-text suggestion to style directives, store
-- the raw text (capped), optionally attach a rating to an interaction, and
-- return the merged directives so the client can confirm. Owner-scoped.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ai_apply_suggestion(
  p_suggestion text,
  p_rating smallint DEFAULT 0,
  p_interaction uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := auth.uid();
  s   text := lower(coalesce(p_suggestion, ''));
  d   jsonb := '{}'::jsonb;
  note text := nullif(btrim(coalesce(p_suggestion, '')), '');
  merged jsonb;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Deterministic phrase -> directive mapping.
  IF s ~ '(too long|shorter|concise|brief|less text)' THEN
    d := d || jsonb_build_object('length', 'concise');
  ELSIF s ~ '(too short|more detail|longer|elaborate|expand)' THEN
    d := d || jsonb_build_object('length', 'detailed', 'depth', 'deep');
  END IF;
  IF s ~ '(example|examples|for instance)' THEN
    d := d || jsonb_build_object('examples', true);
  END IF;
  IF s ~ '(simpler|simple|plain|easier|layman)' THEN
    d := d || jsonb_build_object('tone', 'plain');
  END IF;
  IF s ~ '(step by step|step-by-step|steps|bullet)' THEN
    d := d || jsonb_build_object('format', 'steps');
  END IF;

  INSERT INTO ai_user_preferences (user_id, style_directives, custom_notes, updated_at)
  VALUES (
    uid,
    d,
    CASE WHEN note IS NULL THEN '{}' ELSE ARRAY[left(note, 200)] END,
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    style_directives = ai_user_preferences.style_directives || d,
    custom_notes = (
      -- keep only the most recent 10 raw notes
      (CASE WHEN note IS NULL THEN ai_user_preferences.custom_notes
            ELSE array_append(ai_user_preferences.custom_notes, left(note, 200)) END)
    )[GREATEST(1, array_length(
        CASE WHEN note IS NULL THEN ai_user_preferences.custom_notes
             ELSE array_append(ai_user_preferences.custom_notes, left(note, 200)) END, 1) - 9):],
    updated_at = now()
  RETURNING style_directives INTO merged;

  -- Attach the rating to the originating interaction when provided.
  IF p_interaction IS NOT NULL THEN
    UPDATE ai_interactions
    SET rating = LEAST(GREATEST(COALESCE(p_rating, 0), -1), 1),
        rating_reason = note
    WHERE id = p_interaction AND user_id = uid;
  END IF;

  RETURN merged;
END;
$$;

REVOKE ALL ON FUNCTION ai_apply_suggestion(text, smallint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ai_apply_suggestion(text, smallint, uuid) TO authenticated, service_role;
