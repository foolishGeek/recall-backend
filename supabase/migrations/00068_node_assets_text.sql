-- Phase 7: asset text extraction columns. The extract-asset-text Edge Function
-- will fill these; for now every existing asset is pending and the stub marks
-- unsupported mime types without breaking the PDF path.

SET search_path = public, extensions;

ALTER TABLE node_assets
  ADD COLUMN IF NOT EXISTS extracted_text text,
  ADD COLUMN IF NOT EXISTS parse_status text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS caption text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'node_assets_parse_status_chk'
  ) THEN
    ALTER TABLE node_assets
      ADD CONSTRAINT node_assets_parse_status_chk
      CHECK (parse_status IN (
        'pending', 'processing', 'ready', 'failed', 'unsupported'
      ));
  END IF;
END $$;

COMMENT ON COLUMN node_assets.extracted_text IS
  'Plain text extracted from the asset (PDF pages, OCR, etc.).';
COMMENT ON COLUMN node_assets.parse_status IS
  'pending | processing | ready | failed | unsupported';
COMMENT ON COLUMN node_assets.caption IS
  'Optional human or model caption for images / non-text assets.';

CREATE INDEX IF NOT EXISTS idx_node_assets_parse_pending
  ON node_assets (parse_status)
  WHERE parse_status IN ('pending', 'failed');
