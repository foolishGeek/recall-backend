// revenuecat-webhook (S23) — RevenueCat -> subscriptions/profiles/credits.
// This function does I/O only: it verifies the shared-secret Authorization
// header, reads the [D-EF-6] event subset, and hands the event to the
// apply_revenuecat_event() SQL function (service role) which owns ALL billing
// state changes atomically + idempotently. Deployed with verify_jwt = false
// (config.toml) so RevenueCat can POST without a Supabase JWT.
// Spec: Roadmap/sprints/S23-paywall.md · [D-EF-6] [D-EF-8] [D-PAY-2].

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, jsonResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";

/** Constant-time string compare so the secret can't leak via timing. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

interface RcEvent {
  id?: string;
  type?: string;
  app_user_id?: string;
  product_id?: string;
  store?: string;
  transaction_id?: string;
  purchased_at_ms?: number;
  expiration_at_ms?: number;
  entitlement_ids?: string[];
  environment?: string;
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") {
    return errorResponse("invalid_input", "Only POST is accepted.");
  }

  // Auth: RevenueCat is configured to send Authorization: <shared secret>.
  // Verify before reading the body so we never act on an unsigned request.
  const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  const provided = req.headers.get("Authorization") ?? "";
  if (!expected || !safeEqual(provided, expected)) {
    return errorResponse("unauthorized", "Invalid webhook signature.");
  }

  let body: { event?: RcEvent };
  try {
    body = await req.json();
  } catch (_) {
    return errorResponse("invalid_input", "Malformed JSON body.");
  }

  const event = body?.event;
  if (!event || !event.id || !event.type || !event.app_user_id) {
    return errorResponse("invalid_input", "Missing event fields.");
  }

  // Only forward the subset we read [D-EF-6]; the SQL function does the mapping.
  const payload = {
    id: event.id,
    type: event.type,
    app_user_id: event.app_user_id,
    product_id: event.product_id ?? null,
    store: event.store ?? null,
    transaction_id: event.transaction_id ?? null,
    purchased_at_ms: event.purchased_at_ms ?? null,
    expiration_at_ms: event.expiration_at_ms ?? null,
  };

  const supabase = adminClient();
  const { data, error } = await supabase.rpc("apply_revenuecat_event", {
    p_event: payload,
  });

  if (error) {
    console.error("apply_revenuecat_event failed:", error, "event:", event.id);
    return errorResponse("provider_error", error.message);
  }

  // Always 200 on a handled event (incl. duplicate/ignored) so RevenueCat does
  // not retry-storm a request we processed correctly.
  return jsonResponse({ ok: true, result: data });
});
