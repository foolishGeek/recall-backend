-- Phase 9: dataset / eval / pricing seams only — no training.
-- Private ai-datasets storage bucket for future JSONL exports.

SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- Datasets
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_datasets (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  task       text NOT NULL,
  version    text NOT NULL DEFAULT 'v1',
  notes      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, version)
);

CREATE TABLE IF NOT EXISTS ai_dataset_items (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_id            uuid NOT NULL REFERENCES ai_datasets(id) ON DELETE CASCADE,
  example               jsonb NOT NULL,
  split                 text NOT NULL DEFAULT 'train',
  source_interaction_id uuid REFERENCES ai_interactions(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ai_dataset_items_split_chk
    CHECK (split IN ('train', 'validation', 'test'))
);

CREATE INDEX IF NOT EXISTS idx_ai_dataset_items_dataset
  ON ai_dataset_items (dataset_id, split);

ALTER TABLE ai_datasets ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_dataset_items ENABLE ROW LEVEL SECURITY;
-- Service-role only; no authenticated policies.

-- ---------------------------------------------------------------------
-- Model pricing (currency cost per million tokens)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_model_pricing (
  model            text NOT NULL,
  provider         text NOT NULL,
  input_per_mtok   numeric(12,6) NOT NULL,
  output_per_mtok  numeric(12,6) NOT NULL,
  currency         text NOT NULL DEFAULT 'USD',
  effective_from   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (model, provider, effective_from)
);

ALTER TABLE ai_model_pricing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_model_pricing_read ON ai_model_pricing;
CREATE POLICY ai_model_pricing_read ON ai_model_pricing
  FOR SELECT TO authenticated USING (true);

INSERT INTO ai_model_pricing (model, provider, input_per_mtok, output_per_mtok, currency, effective_from)
VALUES
  ('gemini-1.5-flash', 'gemini', 0.075, 0.30, 'USD', '2025-01-01'::timestamptz),
  ('claude-sonnet-4-20250514', 'anthropic', 3.00, 15.00, 'USD', '2025-01-01'::timestamptz),
  ('gpt-4o-mini', 'openai', 0.15, 0.60, 'USD', '2025-01-01'::timestamptz),
  ('text-embedding-3-small', 'openai', 0.02, 0.00, 'USD', '2025-01-01'::timestamptz)
ON CONFLICT (model, provider, effective_from) DO NOTHING;

-- ---------------------------------------------------------------------
-- Eval runs / cases (minimal)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai_eval_runs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  task        text NOT NULL,
  model       text,
  provider    text,
  dataset_id  uuid REFERENCES ai_datasets(id) ON DELETE SET NULL,
  metrics     jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ai_eval_cases (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id          uuid NOT NULL REFERENCES ai_eval_runs(id) ON DELETE CASCADE,
  dataset_item_id uuid REFERENCES ai_dataset_items(id) ON DELETE SET NULL,
  input           jsonb,
  expected        jsonb,
  output          jsonb,
  score           numeric(8,4),
  passed          boolean,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_eval_cases_run
  ON ai_eval_cases (run_id);

ALTER TABLE ai_eval_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_eval_cases ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- Private storage bucket for dataset exports
-- ---------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public)
VALUES ('ai-datasets', 'ai-datasets', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- No authenticated object policies: service_role writes; signed URLs for read.
-- Explicit revoke of any inherited client write path on the bucket folder.

COMMENT ON TABLE ai_datasets IS
  'Named versioned training/eval datasets. Items hold normalised examples; export writes JSONL to storage.ai-datasets.';
COMMENT ON TABLE ai_model_pricing IS
  'Per-model token pricing so request cost can be compared against self-host economics.';
