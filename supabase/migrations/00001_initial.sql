-- Sprint 01 -- initial Recall schema, RLS, storage, views, helpers, and seeds.
-- Source: Roadmap/sprints/S01-schema-migrations.md; tie-breaker: CANON-DECISIONS.md.

SET search_path = public, extensions;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_tier') THEN
    CREATE TYPE subscription_tier AS ENUM ('free', 'premium');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'store_platform') THEN
    CREATE TYPE store_platform AS ENUM ('app_store', 'play_store');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'device_platform') THEN
    CREATE TYPE device_platform AS ENUM ('ios', 'android');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'node_type') THEN
    CREATE TYPE node_type AS ENUM ('text', 'link', 'youtube', 'pdf', 'image');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'node_state') THEN
    CREATE TYPE node_state AS ENUM ('new', 'learning', 'review', 'relearning', 'leech');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'review_grade') THEN
    CREATE TYPE review_grade AS ENUM ('again', 'hard', 'good', 'easy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'review_source') THEN
    CREATE TYPE review_source AS ENUM ('stack', 'quiz');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'stack_status') THEN
    CREATE TYPE stack_status AS ENUM ('active', 'completed', 'abandoned');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'quiz_mode') THEN
    CREATE TYPE quiz_mode AS ENUM ('freehand', 'by_bucket', 'by_node');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'quiz_question_type') THEN
    CREATE TYPE quiz_question_type AS ENUM ('mcq', 'short_answer', 'flashcard', 'mix');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'quiz_attempt_status') THEN
    CREATE TYPE quiz_attempt_status AS ENUM ('in_progress', 'completed', 'abandoned');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_event_type') THEN
    CREATE TYPE notification_event_type AS ENUM ('sent', 'delivered', 'opened');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_feature') THEN
    CREATE TYPE ai_feature AS ENUM ('embed','rag_chat','summarize','evaluate','quiz_generate','quiz_grade','link_preview');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  timezone text NOT NULL DEFAULT 'UTC',
  locale text NOT NULL DEFAULT 'en',
  theme text NOT NULL DEFAULT 'system' CHECK (theme IN ('system','light','dark')),
  onboarding_done boolean NOT NULL DEFAULT false,
  push_opt_in boolean NOT NULL DEFAULT false,
  drop_frequency text NOT NULL DEFAULT 'daily',
  quiet_hours_start time,
  quiet_hours_end time,
  default_cooling_period interval NOT NULL DEFAULT '24 hours',
  xp integer NOT NULL DEFAULT 0,
  level integer NOT NULL DEFAULT 1,
  current_streak integer NOT NULL DEFAULT 0,
  longest_streak integer NOT NULL DEFAULT 0,
  last_streak_activity_date date,
  retention_with_recall numeric(5,2),
  retention_baseline numeric(5,2),
  memories_saved integer NOT NULL DEFAULT 0,
  had_premium boolean NOT NULL DEFAULT false,
  ai_credit_balance integer NOT NULL DEFAULT 0,
  ai_cooldown_until timestamptz,
  ai_usage_period text,
  ai_requests_month integer NOT NULL DEFAULT 0,
  ai_overviews_month integer NOT NULL DEFAULT 0,
  display_name text,
  haptics_on_drop boolean NOT NULL DEFAULT true,
  analytics_opt_in boolean NOT NULL DEFAULT true,
  session_size_override smallint,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS subscriptions (
  user_id uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  tier subscription_tier NOT NULL DEFAULT 'free',
  revenuecat_app_user_id text,
  product_id text,
  store store_platform,
  expires_at timestamptz,
  will_renew boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS device_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  platform device_platform NOT NULL,
  token text NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, token)
);
CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);

CREATE TABLE IF NOT EXISTS buckets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name text NOT NULL,
  cooling_period interval NOT NULL DEFAULT '24 hours',
  frequency text NOT NULL DEFAULT 'daily',
  cooldown_until timestamptz,
  heat_summary jsonb NOT NULL DEFAULT '{}',
  mastery_pct numeric(5,2),
  daily_cap smallint,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_buckets_user_active ON buckets(user_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS nodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id uuid NOT NULL REFERENCES buckets(id) ON DELETE CASCADE,
  type node_type NOT NULL DEFAULT 'text',
  title text NOT NULL DEFAULT '',
  markdown text,
  url text,
  link_preview_json jsonb,
  difficulty smallint NOT NULL DEFAULT 3 CHECK (difficulty BETWEEN 1 AND 5),
  priority smallint NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  comfort smallint NOT NULL DEFAULT 50 CHECK (comfort BETWEEN 0 AND 100),
  stability numeric(12,4),
  last_reviewed_at timestamptz,
  due_at timestamptz,
  reps integer NOT NULL DEFAULT 0,
  lapses integer NOT NULL DEFAULT 0,
  state node_state NOT NULL DEFAULT 'new',
  last_grade review_grade,
  last_response_ms integer,
  extracted_text text,
  content_hash text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_nodes_bucket_active ON nodes(bucket_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_nodes_due ON nodes(due_at) WHERE deleted_at IS NULL AND state IN ('review','relearning');

CREATE TABLE IF NOT EXISTS node_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  node_id uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  mime_type text NOT NULL,
  file_size_bytes integer,
  sort_order smallint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_node_assets_node ON node_assets(node_id);

CREATE TABLE IF NOT EXISTS node_chunks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  node_id uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  chunk_index integer NOT NULL,
  content text NOT NULL,
  embedding vector(1536),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (node_id, chunk_index)
);
DO $$
BEGIN
  BEGIN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_node_chunks_embedding ON node_chunks USING hnsw (embedding vector_cosine_ops)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'HNSW index unavailable, falling back to ivfflat: %', SQLERRM;
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_node_chunks_embedding_ivfflat ON node_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
  END;
END $$;

CREATE TABLE IF NOT EXISTS node_ai_evaluations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  node_id uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  quality_score smallint CHECK (quality_score BETWEEN 0 AND 100),
  suggested_comfort smallint CHECK (suggested_comfort BETWEEN 0 AND 100),
  suggested_difficulty smallint CHECK (suggested_difficulty BETWEEN 1 AND 5),
  feedback text,
  model text,
  content_hash text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_node_ai_eval_node ON node_ai_evaluations(node_id, created_at DESC);

CREATE TABLE IF NOT EXISTS tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_user_lower_name ON tags(user_id, lower(name));

CREATE TABLE IF NOT EXISTS node_tags (
  node_id uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (node_id, tag_id)
);

CREATE TABLE IF NOT EXISTS stacks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  scope jsonb NOT NULL DEFAULT '{"bucket_ids": []}',
  status stack_status NOT NULL DEFAULT 'active',
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_stacks_user_active ON stacks(user_id) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS stack_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stack_id uuid NOT NULL REFERENCES stacks(id) ON DELETE CASCADE,
  node_id uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  position smallint NOT NULL,
  heat_snapshot numeric(12,4),
  reviewed boolean NOT NULL DEFAULT false,
  UNIQUE (stack_id, node_id),
  UNIQUE (stack_id, position)
);

CREATE TABLE IF NOT EXISTS quiz_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  mode quiz_mode NOT NULL,
  bucket_ids uuid[],
  node_ids uuid[],
  prompt text,
  use_my_notes boolean NOT NULL DEFAULT true,
  question_count smallint NOT NULL DEFAULT 10,
  question_type quiz_question_type NOT NULL DEFAULT 'mcq',
  difficulty smallint NOT NULL DEFAULT 3 CHECK (difficulty BETWEEN 1 AND 5),
  timer_sec integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quiz_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  config_id uuid REFERENCES quiz_configs(id) ON DELETE SET NULL,
  mode quiz_mode NOT NULL,
  question_type quiz_question_type NOT NULL,
  status quiz_attempt_status NOT NULL DEFAULT 'in_progress',
  score_pct numeric(5,2),
  question_count smallint,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quiz_question_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  attempt_id uuid NOT NULL REFERENCES quiz_attempts(id) ON DELETE CASCADE,
  node_id uuid REFERENCES nodes(id) ON DELETE SET NULL,
  bucket_id uuid REFERENCES buckets(id) ON DELETE SET NULL,
  question_json jsonb NOT NULL,
  user_answer text,
  grade review_grade,
  is_correct boolean,
  ai_feedback text,
  response_ms integer,
  timed_out boolean NOT NULL DEFAULT false,
  position smallint NOT NULL,
  answered_at timestamptz,
  comfort_before smallint,
  comfort_after smallint,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (attempt_id, position)
);

CREATE TABLE IF NOT EXISTS reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  node_id uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  stack_id uuid REFERENCES stacks(id) ON DELETE SET NULL,
  quiz_attempt_id uuid REFERENCES quiz_attempts(id) ON DELETE SET NULL,
  source review_source NOT NULL DEFAULT 'stack',
  idempotency_key text NOT NULL,
  grade review_grade NOT NULL,
  stability_before numeric(12,4),
  stability_after numeric(12,4),
  difficulty_before smallint,
  difficulty_after smallint,
  comfort_before smallint,
  comfort_after smallint,
  retrievability_before numeric(8,6),
  retrievability_after numeric(8,6),
  due_before timestamptz,
  due_after timestamptz,
  response_ms integer,
  reviewed_at timestamptz NOT NULL DEFAULT now(),
  client_timestamp timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_reviews_user_date ON reviews(user_id, reviewed_at DESC);
CREATE INDEX IF NOT EXISTS idx_reviews_node ON reviews(node_id, reviewed_at DESC);

CREATE TABLE IF NOT EXISTS user_usage_monthly (
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  period text NOT NULL,
  stacks_created integer NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, period)
);

CREATE TABLE IF NOT EXISTS achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text UNIQUE NOT NULL,
  title text NOT NULL,
  description text,
  xp_reward integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS user_achievements (
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  achievement_id uuid NOT NULL REFERENCES achievements(id) ON DELETE CASCADE,
  unlocked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS daily_activity (
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  activity_date date NOT NULL,
  review_count integer NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, activity_date)
);

CREATE TABLE IF NOT EXISTS app_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES profiles(id) ON DELETE SET NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  platform text,
  app_version text
);

CREATE TABLE IF NOT EXISTS notification_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  type notification_event_type NOT NULL,
  dedupe_key text NOT NULL,
  stack_id uuid REFERENCES stacks(id) ON DELETE SET NULL,
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dedupe_key, type)
);
CREATE INDEX IF NOT EXISTS idx_notification_events_user ON notification_events(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS ai_usage (
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  usage_date date NOT NULL,
  feature ai_feature NOT NULL,
  request_count integer NOT NULL DEFAULT 0,
  input_tokens bigint NOT NULL DEFAULT 0,
  output_tokens bigint NOT NULL DEFAULT 0,
  model text,
  PRIMARY KEY (user_id, usage_date, feature)
);

CREATE TABLE IF NOT EXISTS scheduling_params (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  bucket_id uuid REFERENCES buckets(id) ON DELETE CASCADE,
  target_retention numeric(4,3) NOT NULL DEFAULT 0.90,
  w1 numeric NOT NULL DEFAULT 0.4,
  w2 numeric NOT NULL DEFAULT 0.2,
  w3 numeric NOT NULL DEFAULT 0.8,
  w4 numeric NOT NULL DEFAULT 0.5,
  w5 numeric NOT NULL DEFAULT 0.5,
  w6 numeric NOT NULL DEFAULT 0.5,
  w7 numeric NOT NULL DEFAULT 0.2,
  w8 numeric NOT NULL DEFAULT 0.15,
  s_min numeric NOT NULL DEFAULT 0.1,
  comfort_k numeric NOT NULL DEFAULT 21,
  hard_penalty numeric NOT NULL DEFAULT 0.8,
  easy_bonus numeric NOT NULL DEFAULT 1.3,
  new_per_day smallint NOT NULL DEFAULT 5,
  session_size smallint NOT NULL DEFAULT 12,
  max_new_per_stack smallint NOT NULL DEFAULT 3,
  max_per_bucket smallint NOT NULL DEFAULT 6,
  lookahead_hours smallint NOT NULL DEFAULT 12,
  temperature numeric NOT NULL DEFAULT 1.2,
  drop_threshold smallint NOT NULL DEFAULT 5,
  leech_lapse_threshold smallint NOT NULL DEFAULT 8,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (user_id, bucket_id)
);

CREATE TABLE IF NOT EXISTS app_config (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ai_credit_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  delta integer NOT NULL,
  balance_after integer NOT NULL,
  source text NOT NULL,
  revenuecat_transaction_id text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ai_credit_ledger_user ON ai_credit_ledger(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS ai_rate_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  feature ai_feature NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ai_rate_events_user_hour ON ai_rate_events(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION owns_bucket(target_bucket_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM buckets b
    WHERE b.id = target_bucket_id AND b.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION owns_node(target_node_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM nodes n
    JOIN buckets b ON b.id = n.bucket_id
    WHERE n.id = target_node_id AND b.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION owns_tag(target_tag_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM tags t
    WHERE t.id = target_tag_id AND t.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION owns_stack(target_stack_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM stacks s
    WHERE s.id = target_stack_id AND s.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION owns_quiz_config(target_config_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM quiz_configs qc
    WHERE qc.id = target_config_id AND qc.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION owns_quiz_attempt(target_attempt_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM quiz_attempts qa
    WHERE qa.id = target_attempt_id AND qa.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION match_chunks(
  query_embedding vector(1536),
  match_user_id uuid,
  match_count int DEFAULT 8,
  match_threshold float DEFAULT 0.7,
  filter_bucket_ids uuid[] DEFAULT NULL,
  filter_node_ids uuid[] DEFAULT NULL
)
RETURNS TABLE (node_id uuid, chunk_id uuid, content text, similarity float)
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT nc.node_id, nc.id, nc.content, 1 - (nc.embedding <=> query_embedding) AS similarity
  FROM node_chunks nc
  JOIN nodes n ON n.id = nc.node_id
  JOIN buckets b ON b.id = n.bucket_id
  WHERE (auth.uid() = match_user_id OR auth.role() = 'service_role')
    AND b.user_id = match_user_id
    AND n.deleted_at IS NULL
    AND b.deleted_at IS NULL
    AND nc.embedding IS NOT NULL
    AND (filter_bucket_ids IS NULL OR b.id = ANY(filter_bucket_ids))
    AND (filter_node_ids IS NULL OR n.id = ANY(filter_node_ids))
    AND 1 - (nc.embedding <=> query_embedding) > match_threshold
  ORDER BY nc.embedding <=> query_embedding
  LIMIT match_count;
$$;

CREATE OR REPLACE VIEW v_bucket_mastery WITH (security_invoker = true) AS
SELECT b.id AS bucket_id, b.user_id,
       round((sum(n.comfort * n.difficulty)::numeric / NULLIF(sum(n.difficulty),0)), 1) AS mastery_pct
FROM buckets b JOIN nodes n ON n.bucket_id = b.id
WHERE b.deleted_at IS NULL AND n.deleted_at IS NULL
GROUP BY b.id, b.user_id;

CREATE OR REPLACE VIEW v_bucket_heat WITH (security_invoker = true) AS
SELECT b.id AS bucket_id, b.user_id,
       count(n.*) AS node_count,
       count(*) FILTER (WHERE n.due_at <= now()) AS due_count,
       max(n.priority) AS dominant_priority
FROM buckets b LEFT JOIN nodes n ON n.bucket_id = b.id AND n.deleted_at IS NULL
WHERE b.deleted_at IS NULL
GROUP BY b.id, b.user_id;

CREATE OR REPLACE VIEW v_weak_topics WITH (security_invoker = true) AS
SELECT n.id AS node_id, n.title, b.id AS bucket_id, b.name AS bucket_name,
       n.comfort, n.priority, n.difficulty
FROM nodes n JOIN buckets b ON b.id = n.bucket_id
WHERE n.deleted_at IS NULL AND n.comfort < 40 AND n.difficulty >= 4;

CREATE OR REPLACE VIEW v_daily_activity WITH (security_invoker = true) AS
SELECT user_id, activity_date, review_count
FROM daily_activity
WHERE activity_date >= current_date - INTERVAL '84 days';

CREATE OR REPLACE VIEW v_insights_summary WITH (security_invoker = true) AS
SELECT p.id AS user_id, p.current_streak,
  (SELECT round(100.0 * count(*) FILTER (WHERE r.reviewed_at <= r.due_before)
              / NULLIF(count(*) FILTER (WHERE r.due_before IS NOT NULL),0), 1)
     FROM reviews r WHERE r.user_id = p.id AND r.reviewed_at >= now() - interval '7 days') AS adherence_7d,
  (SELECT count(DISTINCT activity_date) FROM daily_activity d WHERE d.user_id = p.id) AS days_with_reviews,
  (SELECT count(*) FROM nodes n JOIN buckets b ON b.id = n.bucket_id
     WHERE b.user_id = p.id AND n.deleted_at IS NULL AND n.due_at::date = current_date) AS due_today,
  (SELECT count(*) FROM nodes n JOIN buckets b ON b.id = n.bucket_id
     WHERE b.user_id = p.id AND n.deleted_at IS NULL AND n.due_at < now()) AS overdue
FROM profiles p;

CREATE OR REPLACE VIEW v_review_velocity_daily WITH (security_invoker = true) AS
SELECT user_id, activity_date, review_count FROM daily_activity
WHERE activity_date >= current_date - INTERVAL '14 days';

CREATE OR REPLACE VIEW v_notification_daily WITH (security_invoker = true) AS
SELECT user_id, created_at::date AS day,
       count(*) FILTER (WHERE type='sent')   AS sent,
       count(*) FILTER (WHERE type='opened') AS opened
FROM notification_events GROUP BY user_id, created_at::date;

CREATE OR REPLACE VIEW v_notification_stats WITH (security_invoker = true) AS
SELECT user_id,
       count(*) FILTER (WHERE type='sent')   AS sent_30d,
       count(*) FILTER (WHERE type='opened') AS opened_30d
FROM notification_events WHERE created_at >= now() - INTERVAL '30 days'
GROUP BY user_id;

CREATE OR REPLACE VIEW v_profile_lifetime WITH (security_invoker = true) AS
SELECT p.id AS user_id,
  (SELECT count(*) FROM reviews r WHERE r.user_id = p.id) AS total_reviews,
  (SELECT count(*) FROM nodes n JOIN buckets b ON b.id = n.bucket_id
     WHERE b.user_id = p.id AND n.deleted_at IS NULL) AS total_nodes,
  (SELECT round(100.0 * count(*) FILTER (WHERE r.reviewed_at <= r.due_before)
              / NULLIF(count(*) FILTER (WHERE r.due_before IS NOT NULL),0), 1)
     FROM reviews r WHERE r.user_id = p.id) AS lifetime_adherence_pct,
  p.created_at AS member_since
FROM profiles p;

CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO profiles (id) VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO subscriptions (user_id, tier) VALUES (NEW.id, 'free')
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION handle_new_user();

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_profiles_updated_at ON profiles;
CREATE TRIGGER set_profiles_updated_at BEFORE UPDATE ON profiles
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_buckets_updated_at ON buckets;
CREATE TRIGGER set_buckets_updated_at BEFORE UPDATE ON buckets
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_nodes_updated_at ON nodes;
CREATE TRIGGER set_nodes_updated_at BEFORE UPDATE ON nodes
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_stacks_updated_at ON stacks;
CREATE TRIGGER set_stacks_updated_at BEFORE UPDATE ON stacks
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_subscriptions_updated_at ON subscriptions;
CREATE TRIGGER set_subscriptions_updated_at BEFORE UPDATE ON subscriptions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION check_bucket_limit() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  t subscription_tier;
  cnt integer;
BEGIN
  SELECT COALESCE(s.tier, 'free'::subscription_tier)
  INTO t
  FROM profiles p
  LEFT JOIN subscriptions s ON s.user_id = p.id
  WHERE p.id = NEW.user_id;

  IF t = 'premium' THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO cnt
  FROM buckets
  WHERE user_id = NEW.user_id AND deleted_at IS NULL;

  IF cnt >= 2 THEN
    RAISE EXCEPTION 'free_tier_bucket_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_bucket_limit ON buckets;
CREATE TRIGGER enforce_bucket_limit BEFORE INSERT ON buckets
FOR EACH ROW EXECUTE FUNCTION check_bucket_limit();

CREATE OR REPLACE FUNCTION active_buckets_for_user(uid uuid) RETURNS SETOF buckets
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  profile_had_premium boolean;
  current_tier subscription_tier;
BEGIN
  IF NOT (auth.uid() = uid OR auth.role() = 'service_role') THEN
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

CREATE OR REPLACE FUNCTION on_node_content_hash_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  base_url text;
  service_role_key text;
BEGIN
  IF NEW.content_hash IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.content_hash IS NOT DISTINCT FROM OLD.content_hash THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.extracted_text, '') = '' THEN
    RETURN NEW;
  END IF;

  base_url := nullif(current_setting('app.supabase_url', true), '');
  service_role_key := nullif(current_setting('app.service_role_key', true), '');

  IF base_url IS NULL OR service_role_key IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := base_url || '/functions/v1/ai-forge',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    body := jsonb_build_object(
      'feature', 'embed',
      'payload', jsonb_build_object('node_id', NEW.id)
    ),
    timeout_milliseconds := 5000
  );

  RETURN NEW;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function THEN
    RETURN NEW;
  WHEN OTHERS THEN
    RAISE WARNING 'embed trigger failed for node %: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_node_content_hash_change ON nodes;
CREATE TRIGGER trigger_node_content_hash_change
AFTER INSERT OR UPDATE OF content_hash ON nodes
FOR EACH ROW EXECUTE FUNCTION on_node_content_hash_change();

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_ai_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE stacks ENABLE ROW LEVEL SECURITY;
ALTER TABLE stack_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE quiz_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE quiz_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE quiz_question_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_usage_monthly ENABLE ROW LEVEL SECURITY;
ALTER TABLE achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_activity ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE scheduling_params ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_credit_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_rate_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_select_own ON profiles;
CREATE POLICY profiles_select_own ON profiles FOR SELECT TO authenticated
USING (auth.uid() = id);
DROP POLICY IF EXISTS profiles_update_own ON profiles;
CREATE POLICY profiles_update_own ON profiles FOR UPDATE TO authenticated
USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS subscriptions_select_own ON subscriptions;
CREATE POLICY subscriptions_select_own ON subscriptions FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS device_tokens_owner_all ON device_tokens;
CREATE POLICY device_tokens_owner_all ON device_tokens FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS buckets_owner_all ON buckets;
CREATE POLICY buckets_owner_all ON buckets FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS nodes_owner_all ON nodes;
CREATE POLICY nodes_owner_all ON nodes FOR ALL TO authenticated
USING (owns_bucket(bucket_id)) WITH CHECK (owns_bucket(bucket_id));

DROP POLICY IF EXISTS node_assets_owner_all ON node_assets;
CREATE POLICY node_assets_owner_all ON node_assets FOR ALL TO authenticated
USING (owns_node(node_id)) WITH CHECK (owns_node(node_id));

DROP POLICY IF EXISTS node_chunks_select_owner ON node_chunks;
CREATE POLICY node_chunks_select_owner ON node_chunks FOR SELECT TO authenticated
USING (owns_node(node_id));

DROP POLICY IF EXISTS node_ai_evaluations_select_owner ON node_ai_evaluations;
CREATE POLICY node_ai_evaluations_select_owner ON node_ai_evaluations FOR SELECT TO authenticated
USING (owns_node(node_id));

DROP POLICY IF EXISTS tags_owner_all ON tags;
CREATE POLICY tags_owner_all ON tags FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS node_tags_owner_all ON node_tags;
CREATE POLICY node_tags_owner_all ON node_tags FOR ALL TO authenticated
USING (owns_node(node_id) AND owns_tag(tag_id))
WITH CHECK (owns_node(node_id) AND owns_tag(tag_id));

DROP POLICY IF EXISTS stacks_owner_all ON stacks;
CREATE POLICY stacks_owner_all ON stacks FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS stack_items_owner_all ON stack_items;
CREATE POLICY stack_items_owner_all ON stack_items FOR ALL TO authenticated
USING (owns_stack(stack_id) AND owns_node(node_id))
WITH CHECK (owns_stack(stack_id) AND owns_node(node_id));

DROP POLICY IF EXISTS quiz_configs_owner_all ON quiz_configs;
CREATE POLICY quiz_configs_owner_all ON quiz_configs FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS quiz_attempts_owner_all ON quiz_attempts;
CREATE POLICY quiz_attempts_owner_all ON quiz_attempts FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS quiz_question_attempts_owner_all ON quiz_question_attempts;
CREATE POLICY quiz_question_attempts_owner_all ON quiz_question_attempts FOR ALL TO authenticated
USING (owns_quiz_attempt(attempt_id)) WITH CHECK (owns_quiz_attempt(attempt_id));

DROP POLICY IF EXISTS reviews_select_own ON reviews;
CREATE POLICY reviews_select_own ON reviews FOR SELECT TO authenticated
USING (auth.uid() = user_id);
DROP POLICY IF EXISTS reviews_insert_own ON reviews;
CREATE POLICY reviews_insert_own ON reviews FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id AND owns_node(node_id));

DROP POLICY IF EXISTS user_usage_monthly_select_own ON user_usage_monthly;
CREATE POLICY user_usage_monthly_select_own ON user_usage_monthly FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS achievements_select_authenticated ON achievements;
CREATE POLICY achievements_select_authenticated ON achievements FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS user_achievements_select_own ON user_achievements;
CREATE POLICY user_achievements_select_own ON user_achievements FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS daily_activity_select_own ON daily_activity;
CREATE POLICY daily_activity_select_own ON daily_activity FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS app_sessions_owner_all ON app_sessions;
CREATE POLICY app_sessions_owner_all ON app_sessions FOR ALL TO authenticated
USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS notification_events_select_own ON notification_events;
CREATE POLICY notification_events_select_own ON notification_events FOR SELECT TO authenticated
USING (auth.uid() = user_id);
DROP POLICY IF EXISTS notification_events_insert_own ON notification_events;
CREATE POLICY notification_events_insert_own ON notification_events FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS ai_usage_select_own ON ai_usage;
CREATE POLICY ai_usage_select_own ON ai_usage FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS scheduling_params_select_authenticated ON scheduling_params;
CREATE POLICY scheduling_params_select_authenticated ON scheduling_params FOR SELECT TO authenticated
USING (
  (user_id IS NULL AND bucket_id IS NULL)
  OR auth.uid() = user_id
  OR owns_bucket(bucket_id)
);

DROP POLICY IF EXISTS app_config_select_authenticated ON app_config;
CREATE POLICY app_config_select_authenticated ON app_config FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS ai_credit_ledger_select_own ON ai_credit_ledger;
CREATE POLICY ai_credit_ledger_select_own ON ai_credit_ledger FOR SELECT TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS ai_rate_events_select_own ON ai_rate_events;
CREATE POLICY ai_rate_events_select_own ON ai_rate_events FOR SELECT TO authenticated
USING (auth.uid() = user_id);

INSERT INTO storage.buckets (id, name, public)
VALUES
  ('node-pdfs', 'node-pdfs', false),
  ('node-images', 'node-images', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS node_assets_storage_select ON storage.objects;
CREATE POLICY node_assets_storage_select ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS node_assets_storage_insert ON storage.objects;
CREATE POLICY node_assets_storage_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS node_assets_storage_update ON storage.objects;
CREATE POLICY node_assets_storage_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS node_assets_storage_delete ON storage.objects;
CREATE POLICY node_assets_storage_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id IN ('node-pdfs', 'node-images')
  AND (storage.foldername(name))[1] = auth.uid()::text
);

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON
  v_bucket_mastery,
  v_bucket_heat,
  v_weak_topics,
  v_daily_activity,
  v_insights_summary,
  v_review_velocity_daily,
  v_notification_daily,
  v_notification_stats,
  v_profile_lifetime
TO authenticated;
GRANT EXECUTE ON FUNCTION
  active_buckets_for_user(uuid),
  match_chunks(vector(1536), uuid, int, float, uuid[], uuid[])
TO authenticated;

INSERT INTO scheduling_params (user_id, bucket_id)
VALUES (NULL, NULL)
ON CONFLICT (user_id, bucket_id) DO NOTHING;

INSERT INTO app_config (key, value) VALUES
  ('ai_enabled','true'::jsonb),
  ('ai_quota_free_monthly','50'::jsonb),
  ('ai_overview_free_monthly','2'::jsonb),
  ('ai_premium_hourly_burst','100'::jsonb),
  ('ai_premium_cooldown_hours','5'::jsonb),
  ('ai_credit_cost_per_request','1'::jsonb),
  ('ai_chunk_size_tokens','500'::jsonb),
  ('ai_chunk_overlap_tokens','50'::jsonb),
  ('ai_rag_top_k','8'::jsonb),
  ('ai_rag_similarity_threshold','0.7'::jsonb),
  ('ai_context_max_chars','12000'::jsonb),
  ('ai_summarize_bucket_max_nodes','20'::jsonb),
  ('ai_node_text_max_chars','8000'::jsonb),
  ('session_size_free','8'::jsonb),
  ('learning_step_minutes','10'::jsonb),
  ('edit_soft_reduce_factor','1.0'::jsonb),
  ('level_xp_divisor','100'::jsonb),
  ('drop_budget_daily','7'::jsonb),
  ('drop_budget_3xwk','3'::jsonb),
  ('drop_budget_weekly','1'::jsonb),
  ('maintenance_mode','false'::jsonb),
  ('ai_model_free','"gemini-1.5-flash"'::jsonb),
  ('ai_model_premium','"claude-sonnet"'::jsonb),
  ('ai_model_fallback','"gpt-4o-mini"'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

INSERT INTO achievements (slug, title, xp_reward) VALUES
  ('first_review','First review',10),
  ('streak_3','3-day streak',20),
  ('streak_7','7-day streak',30),
  ('streak_30','30-day streak',75),
  ('streak_100','100-day streak',200),
  ('stack_complete','First stack done',20),
  ('stacks_10','10 stacks done',60),
  ('bucket_master','Bucket master',80),
  ('memories_10','10 memories saved',40),
  ('memories_50','50 memories saved',120),
  ('quiz_ace','Quiz ace',50),
  ('night_owl','Night owl',25)
ON CONFLICT (slug) DO UPDATE
SET title = EXCLUDED.title,
    xp_reward = EXCLUDED.xp_reward;
