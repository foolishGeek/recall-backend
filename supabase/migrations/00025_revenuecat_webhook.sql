-- Sprint 23 -- RevenueCat webhook (server-authoritative billing).
-- The revenuecat-webhook Edge Function does I/O + signature verification only;
-- ALL billing state changes live here so they are atomic, RLS-safe and
-- replay-proof. Two idempotency layers [D-EF-8]:
--   1. revenuecat_events(event_id PK) -- each RC event applied at most once.
--   2. ai_credit_ledger.revenuecat_transaction_id UNIQUE -- each credit grant once.
-- Event -> state mapping is the S23 §3 table / [D-EF-6]. Tie-breaker:
-- Roadmap/sprints/CANON-DECISIONS.md.

SET search_path = public, extensions;

-- =====================================================================
-- Idempotency ledger for processed RevenueCat events. Service-role only
-- (no client policy); RLS on so it is never exposed via the data API.
-- =====================================================================
CREATE TABLE IF NOT EXISTS revenuecat_events (
  event_id     text PRIMARY KEY,
  event_type   text NOT NULL,
  app_user_id  text,
  processed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE revenuecat_events ENABLE ROW LEVEL SECURITY;

-- =====================================================================
-- apply_revenuecat_event(p_event) -- maps one RC event to subscriptions +
-- profiles + ai_credit_ledger. Idempotent on event.id; returns a small status
-- jsonb the Edge Function echoes back. Runs as the table owner (definer) so it
-- can write the locked billing columns the client may never touch (00003).
-- =====================================================================
CREATE OR REPLACE FUNCTION apply_revenuecat_event(p_event jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_event_id   text := p_event->>'id';
  v_type       text := p_event->>'type';
  v_app_user   text := p_event->>'app_user_id';
  v_product    text := p_event->>'product_id';
  v_txn        text := COALESCE(p_event->>'transaction_id', p_event->>'id');
  v_store_raw  text := p_event->>'store';
  v_store      store_platform;
  v_expires    timestamptz;
  v_user       uuid;
  v_tier       subscription_tier;
  v_pack       integer;
  v_balance    integer;
BEGIN
  IF v_event_id IS NULL OR v_type IS NULL OR v_app_user IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid_event');
  END IF;

  -- (1) Idempotency: claim this event id; a duplicate replay is a no-op.
  INSERT INTO revenuecat_events (event_id, event_type, app_user_id)
  VALUES (v_event_id, v_type, v_app_user)
  ON CONFLICT (event_id) DO NOTHING;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  -- Resolve the RC app_user_id (Supabase UUID) to a real profile.
  BEGIN
    v_user := v_app_user::uuid;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('status', 'ignored_unknown_user');
  END;

  PERFORM 1 FROM profiles WHERE id = v_user;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'ignored_unknown_user');
  END IF;

  -- Normalize store + expiry once for the subscription branches.
  v_store := CASE upper(COALESCE(v_store_raw, ''))
    WHEN 'APP_STORE'     THEN 'app_store'::store_platform
    WHEN 'MAC_APP_STORE' THEN 'app_store'::store_platform
    WHEN 'PLAY_STORE'    THEN 'play_store'::store_platform
    ELSE NULL
  END;

  IF (p_event->>'expiration_at_ms') IS NOT NULL THEN
    v_expires := to_timestamp((p_event->>'expiration_at_ms')::bigint / 1000.0);
  END IF;

  -- Make sure a subscriptions row exists (handle_new_user seeds one, but be safe).
  INSERT INTO subscriptions (user_id, tier)
  VALUES (v_user, 'free')
  ON CONFLICT (user_id) DO NOTHING;

  -- (2) Map the event type to state. [D-EF-6] / S23 §3.
  CASE v_type
    WHEN 'INITIAL_PURCHASE', 'RENEWAL' THEN
      UPDATE subscriptions
      SET tier        = 'premium',
          will_renew  = true,
          expires_at  = COALESCE(v_expires, expires_at),
          product_id  = COALESCE(v_product, product_id),
          store       = COALESCE(v_store, store),
          revenuecat_app_user_id = v_app_user
      WHERE user_id = v_user;
      UPDATE profiles SET had_premium = true WHERE id = v_user;

    WHEN 'UNCANCELLATION' THEN
      UPDATE subscriptions
      SET tier = 'premium', will_renew = true
      WHERE user_id = v_user;

    WHEN 'CANCELLATION' THEN
      -- Still premium until expires_at; renewal turned off.
      UPDATE subscriptions
      SET tier = 'premium', will_renew = false
      WHERE user_id = v_user;

    WHEN 'EXPIRATION' THEN
      UPDATE subscriptions
      SET tier = 'free', will_renew = false, expires_at = NULL
      WHERE user_id = v_user;

    WHEN 'BILLING_ISSUE' THEN
      UPDATE subscriptions SET will_renew = false WHERE user_id = v_user;

    WHEN 'NON_RENEWING_PURCHASE' THEN
      -- Consumable AI-credit pack. Requires active premium [D-PAY-2].
      SELECT tier INTO v_tier FROM subscriptions WHERE user_id = v_user;
      IF COALESCE(v_tier, 'free') <> 'premium' THEN
        RETURN jsonb_build_object('status', 'rejected_not_premium');
      END IF;

      v_pack := CASE v_product
        WHEN 'ai_credits_100' THEN 100
        WHEN 'ai_credits_500' THEN 500
        ELSE 0
      END;
      IF v_pack = 0 THEN
        RETURN jsonb_build_object('status', 'ignored_unknown_product');
      END IF;

      -- Idempotent grant: the ledger UNIQUE on revenuecat_transaction_id is the
      -- guard. The bump + ledger insert run in one subtransaction (BEGIN ...
      -- EXCEPTION); a duplicate transaction id raises unique_violation which
      -- rolls back the whole block (including the balance bump) automatically,
      -- so there is no double-credit and nothing to compensate.
      BEGIN
        UPDATE profiles
        SET ai_credit_balance = ai_credit_balance + v_pack
        WHERE id = v_user
        RETURNING ai_credit_balance INTO v_balance;

        INSERT INTO ai_credit_ledger
          (user_id, delta, balance_after, source, revenuecat_transaction_id)
        VALUES (v_user, v_pack, v_balance, 'purchase', v_txn);
      EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('status', 'duplicate_transaction');
      END;

      RETURN jsonb_build_object('status', 'credits_granted', 'pack', v_pack,
                                'balance', v_balance);

    ELSE
      -- Unhandled event type (e.g. TRANSFER, SUBSCRIPTION_PAUSED): recorded as
      -- processed so RC stops retrying, but no state change.
      RETURN jsonb_build_object('status', 'ignored_event_type', 'type', v_type);
  END CASE;

  RETURN jsonb_build_object('status', 'applied', 'type', v_type);
END;
$$;

-- Service-role only: the webhook EF runs with the service-role key.
REVOKE ALL ON FUNCTION apply_revenuecat_event(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION apply_revenuecat_event(jsonb) TO service_role;
