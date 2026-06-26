-- Sprint: Aura AI engine [D-AI-8]. Lets a user reset their learned Aura
-- preferences (transparency + control). Owner-scoped via auth.uid().

SET search_path = public, extensions;

CREATE OR REPLACE FUNCTION ai_clear_preferences() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM ai_user_preferences WHERE user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION ai_clear_preferences() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ai_clear_preferences() TO authenticated, service_role;
