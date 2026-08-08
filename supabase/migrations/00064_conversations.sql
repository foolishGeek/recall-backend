-- Phase 6: conversations so Ask Aura is multi-turn and training data is dialogue.
--
-- Today every rag_chat call is single-shot: no history, nothing persisted. That
-- makes follow-ups ("explain the second one") impossible and yields weaker
-- training examples than real conversations. This migration adds the tables;
-- the Edge Function wires history, a question-rewrite step, and a concurrency
-- cap on top.

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS ai_conversations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  title           text,
  scope           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz NOT NULL DEFAULT now(),
  archived_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_ai_conversations_user
  ON ai_conversations (user_id, last_message_at DESC)
  WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS ai_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
  role            text NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'summary')),
  content         text NOT NULL,
  citations       jsonb,
  request_id      uuid REFERENCES ai_requests(id) ON DELETE SET NULL,
  token_count     integer,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_conversation
  ON ai_messages (conversation_id, created_at);

ALTER TABLE ai_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_conversations_owner ON ai_conversations;
CREATE POLICY ai_conversations_owner ON ai_conversations
  FOR ALL TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS ai_messages_owner ON ai_messages;
CREATE POLICY ai_messages_owner ON ai_messages
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM ai_conversations c
      WHERE c.id = conversation_id AND c.user_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM ai_conversations c
      WHERE c.id = conversation_id AND c.user_id = auth.uid()
    )
  );

-- How many of a user's requests may be in flight at once (chat + others).
INSERT INTO app_config (key, value) VALUES
  ('ai_max_inflight_per_user', '2'::jsonb),
  ('ai_chat_history_max_messages', '12'::jsonb),
  ('ai_chat_history_max_tokens', '3000'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- Policy row for the cheap question-rewrite step (free, own daily cap).
INSERT INTO ai_feature_policy (
  profile, feature, access, counter_pool, free_monthly_cap, premium_monthly_cap,
  free_daily_cap, cost_units, min_tier, allow_downgraded, allow_credits,
  counts_toward_burst, temperature, max_tokens,
  client_denial, client_message, client_quota_message, notes
) VALUES
  ('canon', 'question_rewrite', 'free', NULL, NULL, NULL,
   200, 0, 'free', false, false, false, 0.0, 128,
   'quota', NULL, NULL,
   'Rewrites follow-ups into standalone questions for retrieval. Not user-visible.'),
  ('relaxed', 'question_rewrite', 'free', NULL, NULL, NULL,
   500, 0, 'free', true, false, false, 0.0, 128,
   'quota', NULL, NULL,
   'Rewrites follow-ups into standalone questions for retrieval. Not user-visible.')
ON CONFLICT (profile, feature) DO NOTHING;

-- In-flight count for the concurrency cap. Counts reserved rows that have not
-- yet settled; the sweeper clears abandoned ones so a killed isolate cannot
-- permanently block the user.
CREATE OR REPLACE FUNCTION ai_inflight_count(p_user uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT count(*)::integer
  FROM ai_requests
  WHERE user_id = p_user AND status = 'reserved';
$$;

REVOKE ALL ON FUNCTION ai_inflight_count(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ai_inflight_count(uuid) TO service_role;
