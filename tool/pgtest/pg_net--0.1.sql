-- Test double for pg_net. Records calls instead of making them, so migrations
-- that schedule webhooks install and run without reaching the network.
CREATE SCHEMA IF NOT EXISTS net;

CREATE TABLE IF NOT EXISTS net.sent_requests (
  id      bigserial PRIMARY KEY,
  url     text,
  headers jsonb,
  body    jsonb,
  sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION net.http_post(
  url text,
  body jsonb DEFAULT '{}'::jsonb,
  params jsonb DEFAULT '{}'::jsonb,
  headers jsonb DEFAULT '{}'::jsonb,
  timeout_milliseconds integer DEFAULT 5000
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO net.sent_requests (url, headers, body)
  VALUES (url, headers, body)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
