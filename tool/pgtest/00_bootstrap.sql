-- What Supabase provides before the first migration runs. Recreating it here is
-- what lets the real migration chain execute against a plain Postgres.

-- Roles the migrations GRANT to.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT;
  END IF;
END $$;

-- Supabase installs extensions into their own schema.
CREATE SCHEMA IF NOT EXISTS extensions;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

-- pgcrypto lands in extensions, but gen_random_uuid() is called unqualified all
-- over the migrations, so extensions must be on the search_path for everyone.
ALTER DATABASE :"dbname" SET search_path TO public, extensions;

-- GoTrue's schema, reduced to what the migrations actually touch.
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- Only the columns the migrations read. `confirmed_at` is generated in real
-- GoTrue; a plain column is close enough for migration testing.
CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY,
  email              text UNIQUE,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw_app_meta_data  jsonb NOT NULL DEFAULT '{}'::jsonb,
  email_confirmed_at timestamptz,
  confirmed_at       timestamptz,
  last_sign_in_at    timestamptz,
  deleted_at         timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

-- The current user id, taken from the request JWT claims. Tests set
-- `request.jwt.claims` directly to impersonate a user.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.sub', true),
      (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    current_setting('request.jwt.claim.role', true),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    'authenticated'
  );
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  );
$$;

-- Storage, reduced to the two tables and the helper the RLS policies use.
CREATE SCHEMA IF NOT EXISTS storage;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id         text PRIMARY KEY,
  name       text NOT NULL,
  public     boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id  text REFERENCES storage.buckets(id),
  name       text,
  owner      uuid,
  owner_id   text,
  metadata   jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Splits an object path into its folder segments; policies compare element 1
-- against auth.uid() to scope a user to their own prefix.
CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  parts text[];
BEGIN
  parts := string_to_array(name, '/');
  RETURN parts[1:array_length(parts, 1) - 1];
END;
$$;

-- Vault is referenced by the embed trigger migration for the service-role key.
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE IF NOT EXISTS vault.secrets (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text UNIQUE,
  secret       text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE VIEW vault.decrypted_secrets AS
  SELECT id, name, secret, secret AS decrypted_secret, created_at FROM vault.secrets;
