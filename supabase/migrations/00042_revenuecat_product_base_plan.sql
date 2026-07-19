-- Wave A Play Billing: store identifiers may be `productId:basePlanId`.
-- Credit packs stay bare (`ai_credits_100`); normalize before CASE so a
-- future colon-suffixed id still maps. Subscriptions keep the full
-- store product_id on subscriptions.product_id (informational).

CREATE OR REPLACE FUNCTION apply_revenuecat_event(p_event jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_event_id   text := p_event->>'id';
  v_type       text := p_event->>'type';
  v_app_user   text := p_event->>'app_user_id';
  v_product    text := p_event->>'product_id';
  v_product_base text;
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

  INSERT INTO revenuecat_events (event_id, event_type, app_user_id)
  VALUES (v_event_id, v_type, v_app_user)
  ON CONFLICT (event_id) DO NOTHING;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  BEGIN
    v_user := v_app_user::uuid;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('status', 'ignored_unknown_user');
  END;

  PERFORM 1 FROM profiles WHERE id = v_user;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'ignored_unknown_user');
  END IF;

  v_store := CASE upper(COALESCE(v_store_raw, ''))
    WHEN 'APP_STORE'     THEN 'app_store'::store_platform
    WHEN 'MAC_APP_STORE' THEN 'app_store'::store_platform
    WHEN 'PLAY_STORE'    THEN 'play_store'::store_platform
    ELSE NULL
  END;

  IF (p_event->>'expiration_at_ms') IS NOT NULL THEN
    v_expires := to_timestamp((p_event->>'expiration_at_ms')::bigint / 1000.0);
  END IF;

  INSERT INTO subscriptions (user_id, tier)
  VALUES (v_user, 'free')
  ON CONFLICT (user_id) DO NOTHING;

  -- Strip Play base-plan suffix for credit mapping only.
  v_product_base := split_part(COALESCE(v_product, ''), ':', 1);

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
      SELECT tier INTO v_tier FROM subscriptions WHERE user_id = v_user;
      IF COALESCE(v_tier, 'free') <> 'premium' THEN
        RETURN jsonb_build_object('status', 'rejected_not_premium');
      END IF;

      v_pack := CASE v_product_base
        WHEN 'ai_credits_100' THEN 100
        WHEN 'ai_credits_500' THEN 500
        ELSE 0
      END;
      IF v_pack = 0 THEN
        RETURN jsonb_build_object('status', 'ignored_unknown_product');
      END IF;

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
      RETURN jsonb_build_object('status', 'ignored_event_type', 'type', v_type);
  END CASE;

  RETURN jsonb_build_object('status', 'applied', 'type', v_type);
END;
$$;

REVOKE ALL ON FUNCTION apply_revenuecat_event(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION apply_revenuecat_event(jsonb) TO service_role;
