-- Sprint: Aura AI engine. AI Evaluation now returns a suggested rewrite of the
-- note body so the client can show a git-style diff + apply/revert. Persist the
-- rewrite alongside the cached evaluation so it survives reloads (cache hit).
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md.

ALTER TABLE node_ai_evaluations
  ADD COLUMN IF NOT EXISTS suggested_markdown text;
