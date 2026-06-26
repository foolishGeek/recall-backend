-- S24 · Data export storage + ledger. The `export-user-data` Edge Function
-- builds a single zip per user, overwrites it on each request (one file per
-- user, TTL reset), and signs a short-lived download URL. `user_exports` is the
-- owner-readable status/TTL ledger the Settings screen reads ("Export ready ·
-- expires in Nh"); the hourly cleanup cron (00027) prunes expired files.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-5].

-- Private bucket; only the service role writes (zip upload), only signed URLs
-- read. Owner-only RLS mirrors the node-pdfs / node-images policies (00001).
INSERT INTO storage.buckets (id, name, public)
VALUES ('exports', 'exports', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS exports_storage_select ON storage.objects;
CREATE POLICY exports_storage_select ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'exports'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS exports_storage_insert ON storage.objects;
CREATE POLICY exports_storage_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'exports'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS exports_storage_update ON storage.objects;
CREATE POLICY exports_storage_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'exports'
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'exports'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS exports_storage_delete ON storage.objects;
CREATE POLICY exports_storage_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'exports'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- One row per user (overwritten on each export). created_at/expires_at drive the
-- "ready + TTL" status; the cleanup cron deletes the object + row past expiry.
CREATE TABLE IF NOT EXISTS user_exports (
  user_id      uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL
);

ALTER TABLE user_exports ENABLE ROW LEVEL SECURITY;

-- Owner may read its own status; all writes are service-role only (the EF).
-- The blanket GRANT in 00001 predates this table, so grant SELECT explicitly
-- (matching that migration's style) and revoke any inherited write privileges.
DROP POLICY IF EXISTS user_exports_select_own ON user_exports;
CREATE POLICY user_exports_select_own ON user_exports FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = user_id);

GRANT SELECT ON user_exports TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON user_exports FROM authenticated;

CREATE INDEX IF NOT EXISTS user_exports_expires_at_idx ON user_exports (expires_at);
