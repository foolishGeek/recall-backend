-- Sprint 01 hardening after staging advisor pass.
-- Removes default public function execution and optimizes RLS auth calls.

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION owns_bucket(target_bucket_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM buckets b
    WHERE b.id = target_bucket_id AND b.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION owns_node(target_node_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.id = target_node_id AND b.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION owns_tag(target_tag_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM tags t
    WHERE t.id = target_tag_id AND t.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION owns_stack(target_stack_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM stacks s
    WHERE s.id = target_stack_id AND s.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION owns_quiz_config(target_config_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM quiz_configs qc
    WHERE qc.id = target_config_id AND qc.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION owns_quiz_attempt(target_attempt_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM quiz_attempts qa
    WHERE qa.id = target_attempt_id AND qa.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION active_buckets_for_user(uid uuid) RETURNS SETOF buckets
LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE
  profile_had_premium boolean;
  current_tier subscription_tier;
BEGIN
  IF NOT ((SELECT auth.uid()) = uid OR auth.role() = 'service_role') THEN
    RETURN;
  END IF;

  SELECT p.had_premium, COALESCE(s.tier, 'free'::subscription_tier)
  INTO profile_had_premium, current_tier
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = uid;

  IF current_tier = 'premium' OR NOT COALESCE(profile_had_premium, false) THEN
    RETURN QUERY
    SELECT b.*
    FROM buckets b
    WHERE b.user_id = uid AND b.deleted_at IS NULL
    ORDER BY b.created_at ASC, b.id ASC;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT b.*
  FROM buckets b
  WHERE b.user_id = uid AND b.deleted_at IS NULL
  ORDER BY b.created_at ASC, b.id ASC
  LIMIT 3;
END;
$$;

DROP POLICY IF EXISTS profiles_select_own ON profiles;
CREATE POLICY profiles_select_own ON profiles FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = id);
DROP POLICY IF EXISTS profiles_update_own ON profiles;
CREATE POLICY profiles_update_own ON profiles FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = id) WITH CHECK ((SELECT auth.uid()) = id);

DROP POLICY IF EXISTS subscriptions_select_own ON subscriptions;
CREATE POLICY subscriptions_select_own ON subscriptions FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS device_tokens_owner_all ON device_tokens;
CREATE POLICY device_tokens_owner_all ON device_tokens FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS buckets_owner_all ON buckets;
CREATE POLICY buckets_owner_all ON buckets FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS nodes_owner_all ON nodes;
CREATE POLICY nodes_owner_all ON nodes FOR ALL TO authenticated
USING ((SELECT owns_bucket(bucket_id))) WITH CHECK ((SELECT owns_bucket(bucket_id)));

DROP POLICY IF EXISTS node_assets_owner_all ON node_assets;
CREATE POLICY node_assets_owner_all ON node_assets FOR ALL TO authenticated
USING ((SELECT owns_node(node_id))) WITH CHECK ((SELECT owns_node(node_id)));

DROP POLICY IF EXISTS node_chunks_select_owner ON node_chunks;
CREATE POLICY node_chunks_select_owner ON node_chunks FOR SELECT TO authenticated
USING ((SELECT owns_node(node_id)));

DROP POLICY IF EXISTS node_ai_evaluations_select_owner ON node_ai_evaluations;
CREATE POLICY node_ai_evaluations_select_owner ON node_ai_evaluations FOR SELECT TO authenticated
USING ((SELECT owns_node(node_id)));

DROP POLICY IF EXISTS tags_owner_all ON tags;
CREATE POLICY tags_owner_all ON tags FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS node_tags_owner_all ON node_tags;
CREATE POLICY node_tags_owner_all ON node_tags FOR ALL TO authenticated
USING ((SELECT owns_node(node_id)) AND (SELECT owns_tag(tag_id)))
WITH CHECK ((SELECT owns_node(node_id)) AND (SELECT owns_tag(tag_id)));

DROP POLICY IF EXISTS stacks_owner_all ON stacks;
CREATE POLICY stacks_owner_all ON stacks FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS stack_items_owner_all ON stack_items;
CREATE POLICY stack_items_owner_all ON stack_items FOR ALL TO authenticated
USING ((SELECT owns_stack(stack_id)) AND (SELECT owns_node(node_id)))
WITH CHECK ((SELECT owns_stack(stack_id)) AND (SELECT owns_node(node_id)));

DROP POLICY IF EXISTS quiz_configs_owner_all ON quiz_configs;
CREATE POLICY quiz_configs_owner_all ON quiz_configs FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS quiz_attempts_owner_all ON quiz_attempts;
CREATE POLICY quiz_attempts_owner_all ON quiz_attempts FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS quiz_question_attempts_owner_all ON quiz_question_attempts;
CREATE POLICY quiz_question_attempts_owner_all ON quiz_question_attempts FOR ALL TO authenticated
USING ((SELECT owns_quiz_attempt(attempt_id))) WITH CHECK ((SELECT owns_quiz_attempt(attempt_id)));

DROP POLICY IF EXISTS reviews_select_own ON reviews;
CREATE POLICY reviews_select_own ON reviews FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);
DROP POLICY IF EXISTS reviews_insert_own ON reviews;
CREATE POLICY reviews_insert_own ON reviews FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = user_id AND (SELECT owns_node(node_id)));

DROP POLICY IF EXISTS user_usage_monthly_select_own ON user_usage_monthly;
CREATE POLICY user_usage_monthly_select_own ON user_usage_monthly FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS achievements_select_authenticated ON achievements;
CREATE POLICY achievements_select_authenticated ON achievements FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS user_achievements_select_own ON user_achievements;
CREATE POLICY user_achievements_select_own ON user_achievements FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS daily_activity_select_own ON daily_activity;
CREATE POLICY daily_activity_select_own ON daily_activity FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS app_sessions_owner_all ON app_sessions;
CREATE POLICY app_sessions_owner_all ON app_sessions FOR ALL TO authenticated
USING ((SELECT auth.uid()) = user_id) WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS notification_events_select_own ON notification_events;
CREATE POLICY notification_events_select_own ON notification_events FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);
DROP POLICY IF EXISTS notification_events_insert_own ON notification_events;
CREATE POLICY notification_events_insert_own ON notification_events FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS ai_usage_select_own ON ai_usage;
CREATE POLICY ai_usage_select_own ON ai_usage FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS scheduling_params_select_authenticated ON scheduling_params;
CREATE POLICY scheduling_params_select_authenticated ON scheduling_params FOR SELECT TO authenticated
USING (
  (user_id IS NULL AND bucket_id IS NULL)
  OR (SELECT auth.uid()) = user_id
  OR (SELECT owns_bucket(bucket_id))
);

DROP POLICY IF EXISTS app_config_select_authenticated ON app_config;
CREATE POLICY app_config_select_authenticated ON app_config FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS ai_credit_ledger_select_own ON ai_credit_ledger;
CREATE POLICY ai_credit_ledger_select_own ON ai_credit_ledger FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS ai_rate_events_select_own ON ai_rate_events;
CREATE POLICY ai_rate_events_select_own ON ai_rate_events FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS node_assets_storage_select ON storage.objects;
CREATE POLICY node_assets_storage_select ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

DROP POLICY IF EXISTS node_assets_storage_insert ON storage.objects;
CREATE POLICY node_assets_storage_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

DROP POLICY IF EXISTS node_assets_storage_update ON storage.objects;
CREATE POLICY node_assets_storage_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
)
WITH CHECK (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

DROP POLICY IF EXISTS node_assets_storage_delete ON storage.objects;
CREATE POLICY node_assets_storage_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

REVOKE ALL ON FUNCTION
  owns_bucket(uuid),
  owns_node(uuid),
  owns_tag(uuid),
  owns_stack(uuid),
  owns_quiz_config(uuid),
  owns_quiz_attempt(uuid),
  active_buckets_for_user(uuid),
  match_chunks(vector(1536), uuid, int, float, uuid[], uuid[]),
  handle_new_user(),
  set_updated_at(),
  check_bucket_limit(),
  on_node_content_hash_change()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  owns_bucket(uuid),
  owns_node(uuid),
  owns_tag(uuid),
  owns_stack(uuid),
  owns_quiz_config(uuid),
  owns_quiz_attempt(uuid),
  active_buckets_for_user(uuid),
  match_chunks(vector(1536), uuid, int, float, uuid[], uuid[])
TO authenticated;
