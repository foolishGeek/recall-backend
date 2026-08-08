-- Recall · 00074 — move the free tier off a deprecated Gemini model.
--
-- `gemini-2.5-flash-lite` started answering 404 "this model is no longer
-- available" during a Google config incident, and it is scheduled for shutdown
-- on 2026-10-16 either way. `gemini-3.1-flash-lite` is Google's named
-- replacement: same generateContent shape, same JSON response mime type, same
-- system instruction support, so nothing in the provider changes.
--
-- The canon snapshot moves too. It still pointed at `gemini-1.5-flash`, which
-- was shut down in 2025 — so rollback_limits_to_canon() would have restored the
-- free caps and pointed the free tier at a model that no longer exists. The
-- snapshot is there to restore *caps*, not a model era.

BEGIN;

UPDATE app_config SET value = '"gemini-3.1-flash-lite"'::jsonb, updated_at = now()
WHERE key = 'ai_model_free';

UPDATE app_config SET value = '"gemini-3.1-flash-lite"'::jsonb, updated_at = now()
WHERE key = 'ai_model_free_canon';

-- Price both the outgoing and incoming model so cost stays computable across
-- the switch: interactions already logged were served by 2.5 Flash-Lite.
INSERT INTO ai_model_pricing (model, provider, input_per_mtok, output_per_mtok, currency, effective_from)
VALUES
  ('gemini-2.5-flash-lite', 'gemini', 0.10, 0.40, 'USD', '2025-07-22'::timestamptz),
  ('gemini-3.1-flash-lite', 'gemini', 0.25, 1.50, 'USD', '2026-05-07'::timestamptz)
ON CONFLICT (model, provider, effective_from) DO NOTHING;

CREATE OR REPLACE FUNCTION rollback_limits_to_canon() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'stacks_free_monthly_canon'),
    '2'::jsonb
  ), updated_at = now()
  WHERE key = 'stacks_free_monthly';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'buckets_free_writable_canon'),
    '2'::jsonb
  ), updated_at = now()
  WHERE key = 'buckets_free_writable';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'ai_quota_free_monthly_canon'),
    '50'::jsonb
  ), updated_at = now()
  WHERE key = 'ai_quota_free_monthly';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'ai_overview_free_monthly_canon'),
    '2'::jsonb
  ), updated_at = now()
  WHERE key = 'ai_overview_free_monthly';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'session_size_free_canon'),
    '8'::jsonb
  ), updated_at = now()
  WHERE key = 'session_size_free';

  UPDATE app_config SET value = COALESCE(
    (SELECT value FROM app_config WHERE key = 'ai_model_free_canon'),
    '"gemini-3.1-flash-lite"'::jsonb
  ), updated_at = now()
  WHERE key = 'ai_model_free';
END;
$$;

COMMENT ON FUNCTION rollback_limits_to_canon() IS
  'Restore free-tier caps to canon snapshots (2 stacks, 2 buckets, 50 AI, 2 overviews, 8 cards). The free model follows ai_model_free_canon, which tracks whatever Gemini currently serves.';

COMMIT;
