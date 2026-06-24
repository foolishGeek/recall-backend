-- Sprint 03 backend hardening (pre data-layer).
-- 1) Lock billing/AI/entitlement columns on profiles (service-role/trigger-only).
-- 2) Make gamification (streak/XP/level/daily_activity/achievements) server-authoritative
--    via SECURITY DEFINER triggers on reviews/stacks.
-- 3) Server-enforce free_tier_stack_limit + atomic user_usage_monthly increment.
-- 4) Medium hardening: notification_events insert type guard, single active stack,
--    frequency CHECK constraints.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md. Idempotent + ACID + replay-safe.

SET search_path = public, extensions;

-- =====================================================================
-- A1 — Lock billing/AI/entitlement columns on profiles
-- The client may only edit its own preferences. Everything tied to money,
-- entitlement, or gamification is written by service-role EFs / definer triggers.
-- New columns added later are non-writable by the client by default (safe).
-- RLS profiles_update_own still applies on top of these column grants.
-- =====================================================================
REVOKE UPDATE ON profiles FROM authenticated;
GRANT UPDATE (
  timezone, locale, theme, onboarding_done, push_opt_in,
  drop_frequency, quiet_hours_start, quiet_hours_end, default_cooling_period,
  display_name, haptics_on_drop, analytics_opt_in, session_size_override
) ON profiles TO authenticated;

-- =====================================================================
-- Shared helper: level from xp [D-ENG-12]
-- level = floor(sqrt(xp / level_xp_divisor)) + 1  (divisor from app_config)
-- =====================================================================
CREATE OR REPLACE FUNCTION level_for_xp(p_xp integer) RETURNS integer
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT (floor(sqrt(
    GREATEST(p_xp, 0)::numeric
    / COALESCE((SELECT (value #>> '{}')::int FROM app_config WHERE key = 'level_xp_divisor'), 100)
  )) + 1)::int;
$$;

-- =====================================================================
-- Shared helper: unlock an achievement once and award its xp_reward once.
-- Idempotent via user_achievements PK; xp awarded only on the row actually
-- inserted (FOUND is false when ON CONFLICT DO NOTHING hit a conflict).
-- =====================================================================
CREATE OR REPLACE FUNCTION unlock_achievement(p_user uuid, p_slug text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a_id uuid;
  a_xp integer;
BEGIN
  SELECT id, xp_reward INTO a_id, a_xp FROM achievements WHERE slug = p_slug;
  IF a_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO user_achievements (user_id, achievement_id)
  VALUES (p_user, a_id)
  ON CONFLICT (user_id, achievement_id) DO NOTHING;

  IF FOUND AND COALESCE(a_xp, 0) <> 0 THEN
    UPDATE profiles
    SET xp = xp + a_xp,
        level = level_for_xp(xp + a_xp)
    WHERE id = p_user;
  END IF;
END;
$$;

-- =====================================================================
-- A2 — reviews AFTER INSERT: gamification (server-authoritative)
-- Fires once per successfully inserted review. Replay-safe: a duplicate
-- idempotency_key never inserts, so XP/streak never double-count.
-- The profile row is locked FOR UPDATE to serialize concurrent reviews.
-- =====================================================================
CREATE OR REPLACE FUNCTION on_review_recorded() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  tz          text;
  last_date   date;
  cur_streak  integer;
  today_local date;
  new_streak  integer;
  is_new_day  boolean;
  xp_gain     integer := 5;          -- review XP [S04 §4c]
  local_hour  integer;
BEGIN
  SELECT timezone, last_streak_activity_date, current_streak
    INTO tz, last_date, cur_streak
    FROM profiles
    WHERE id = NEW.user_id
    FOR UPDATE;

  tz := COALESCE(tz, 'UTC');
  today_local := (NEW.reviewed_at AT TIME ZONE tz)::date;
  is_new_day  := (last_date IS DISTINCT FROM today_local);

  -- daily_activity (review count per local day)
  INSERT INTO daily_activity (user_id, activity_date, review_count)
  VALUES (NEW.user_id, today_local, 1)
  ON CONFLICT (user_id, activity_date)
  DO UPDATE SET review_count = daily_activity.review_count + 1;

  -- streak
  IF last_date IS NULL THEN
    new_streak := 1;
  ELSIF last_date = today_local THEN
    new_streak := COALESCE(cur_streak, 0);
  ELSIF last_date = (today_local - 1) THEN
    new_streak := COALESCE(cur_streak, 0) + 1;
  ELSE
    new_streak := 1;
  END IF;

  -- streak-day XP only on the first qualifying review of a new local day
  IF is_new_day THEN
    xp_gain := xp_gain + 10;
  END IF;

  UPDATE profiles
  SET xp = xp + xp_gain,
      current_streak = new_streak,
      longest_streak = GREATEST(longest_streak, new_streak),
      last_streak_activity_date = today_local,
      level = level_for_xp(xp + xp_gain)
  WHERE id = NEW.user_id;

  -- review-driven achievements (others land in their owning sprints)
  PERFORM unlock_achievement(NEW.user_id, 'first_review');
  IF new_streak >= 3   THEN PERFORM unlock_achievement(NEW.user_id, 'streak_3');   END IF;
  IF new_streak >= 7   THEN PERFORM unlock_achievement(NEW.user_id, 'streak_7');   END IF;
  IF new_streak >= 30  THEN PERFORM unlock_achievement(NEW.user_id, 'streak_30');  END IF;
  IF new_streak >= 100 THEN PERFORM unlock_achievement(NEW.user_id, 'streak_100'); END IF;

  local_hour := EXTRACT(hour FROM (NEW.reviewed_at AT TIME ZONE tz))::int;
  IF local_hour >= 0 AND local_hour < 4 THEN
    PERFORM unlock_achievement(NEW.user_id, 'night_owl');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_on_review_recorded ON reviews;
CREATE TRIGGER trg_on_review_recorded
AFTER INSERT ON reviews
FOR EACH ROW EXECUTE FUNCTION on_review_recorded();

-- =====================================================================
-- A3 — stacks BEFORE INSERT: free_tier_stack_limit + atomic usage count
-- Mirrors check_bucket_limit. Definer so it can write user_usage_monthly
-- (no client write policy). On the 3rd stack the RAISE rolls back the
-- increment too, so the count stays correct. Premium bypasses.
-- =====================================================================
CREATE OR REPLACE FUNCTION check_stack_limit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t   subscription_tier;
  tz  text;
  per text;
  cnt integer;
BEGIN
  SELECT COALESCE(s.tier, 'free'::subscription_tier), COALESCE(p.timezone, 'UTC')
    INTO t, tz
    FROM profiles p
    LEFT JOIN subscriptions s ON s.user_id = p.id
    WHERE p.id = NEW.user_id;

  IF t = 'premium' THEN
    RETURN NEW;
  END IF;

  per := to_char((now() AT TIME ZONE tz), 'YYYY-MM');

  INSERT INTO user_usage_monthly (user_id, period, stacks_created)
  VALUES (NEW.user_id, per, 1)
  ON CONFLICT (user_id, period)
  DO UPDATE SET stacks_created = user_usage_monthly.stacks_created + 1
  RETURNING stacks_created INTO cnt;

  IF cnt > 2 THEN
    RAISE EXCEPTION 'free_tier_stack_limit' USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_stack_limit ON stacks;
CREATE TRIGGER enforce_stack_limit
BEFORE INSERT ON stacks
FOR EACH ROW EXECUTE FUNCTION check_stack_limit();

-- =====================================================================
-- A3 (cont) — stacks AFTER UPDATE -> completed: stack XP + achievements
-- =====================================================================
CREATE OR REPLACE FUNCTION on_stack_completed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  completed_cnt integer;
BEGIN
  IF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' THEN
    UPDATE profiles
    SET xp = xp + 25,                 -- stack-complete XP [S04 §4c]
        level = level_for_xp(xp + 25)
    WHERE id = NEW.user_id;

    PERFORM unlock_achievement(NEW.user_id, 'stack_complete');

    SELECT count(*) INTO completed_cnt
    FROM stacks
    WHERE user_id = NEW.user_id AND status = 'completed';

    IF completed_cnt >= 10 THEN
      PERFORM unlock_achievement(NEW.user_id, 'stacks_10');
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_on_stack_completed ON stacks;
CREATE TRIGGER trg_on_stack_completed
AFTER UPDATE OF status ON stacks
FOR EACH ROW EXECUTE FUNCTION on_stack_completed();

-- =====================================================================
-- A4 — Medium hardening
-- =====================================================================

-- notification_events: clients may only write delivered/opened [D-EF-10];
-- 'sent' is service-role only (compute-due).
DROP POLICY IF EXISTS notification_events_insert_own ON notification_events;
CREATE POLICY notification_events_insert_own ON notification_events FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = user_id AND type IN ('delivered', 'opened'));

-- One active stack per user (prevents a double-tap race creating two).
-- Reuses the existing index name; the unique form also serves the lookup.
DROP INDEX IF EXISTS idx_stacks_user_active;
CREATE UNIQUE INDEX IF NOT EXISTS idx_stacks_user_active ON stacks(user_id) WHERE status = 'active';

-- Frequency integrity (matches drop_budget_* keys / [D-ENG-9]).
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_drop_frequency_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_drop_frequency_check
  CHECK (drop_frequency IN ('daily', '3xwk', 'weekly')) NOT VALID;
ALTER TABLE profiles VALIDATE CONSTRAINT profiles_drop_frequency_check;

ALTER TABLE buckets DROP CONSTRAINT IF EXISTS buckets_frequency_check;
ALTER TABLE buckets ADD CONSTRAINT buckets_frequency_check
  CHECK (frequency IN ('daily', '3xwk', 'weekly')) NOT VALID;
ALTER TABLE buckets VALIDATE CONSTRAINT buckets_frequency_check;

-- =====================================================================
-- Function privileges: these run only via triggers (no direct client call).
-- =====================================================================
REVOKE ALL ON FUNCTION
  level_for_xp(integer),
  unlock_achievement(uuid, text),
  on_review_recorded(),
  check_stack_limit(),
  on_stack_completed()
FROM PUBLIC, anon, authenticated;
