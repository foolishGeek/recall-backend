-- Cleanup: retire the dead Recall Drop cadence-budget config.
--
-- drop_budget_daily / drop_budget_3xwk / drop_budget_weekly were the old rolling
-- 7-day send budget. They were superseded by the watermark trigger (00035) and,
-- as of 00049, profiles.drop_frequency now feeds drop_intensity() instead. No
-- current function reads these keys (verified: only historical migrations +
-- docs), so they are safe to remove. Idempotent.
--
-- Heat: engine_heat() already returns 0 and is no longer used by any live
-- eligibility/queue RPC (all rewritten in 00030/00032/00033/00046). The stub is
-- intentionally left in place because older migrations reference it; dropping the
-- function object is unnecessary and higher-risk than leaving a no-op.

SET search_path = public, extensions;

DELETE FROM app_config
WHERE key IN ('drop_budget_daily', 'drop_budget_3xwk', 'drop_budget_weekly');
