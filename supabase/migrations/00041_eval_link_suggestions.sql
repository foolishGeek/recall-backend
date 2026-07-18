-- Aura evaluate may suggest a closer-match URL for an existing note link without
-- removing the original. Persist structured suggestions beside the rewrite cache.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md / AI-PROMPTS.md evaluate.

ALTER TABLE node_ai_evaluations
  ADD COLUMN IF NOT EXISTS link_suggestions jsonb NOT NULL DEFAULT '[]'::jsonb;
