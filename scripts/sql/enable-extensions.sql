-- Run in Supabase SQL Editor (staging and prod). S00 — enable extensions only.
-- Do NOT schedule cron jobs here (S16 owns compute-due schedule).

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Verify:
-- SELECT extname FROM pg_extension WHERE extname IN ('pg_cron', 'pg_net', 'vector', 'pgcrypto');
