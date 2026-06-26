/// <reference lib="deno.ns" />

// retention-simulate [S21]. POST (no body) -> 90-day forgetting-curve payload.
// Premium-only: powers the Insights retention hero + curve and the You-tab
// memory simulation (S22). Owns auth + premium gating + the profile cache write
// (via retention_simulate_rpc); all curve / hero / memories_saved math is
// server-authoritative in SQL. Shape consumed by modules/insights + modules/you:
//   { retention_with_recall, retention_baseline, curve_points[],
//     is_projected, review_days_count, memories_saved }

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { assertAllowed, gateCheck } from "../_shared/quota.ts";
import { adminClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId) throw new AppError("unauthorized");

    // Premium-only; the gate also blocks downgraded + maintenance.
    const gate = await gateCheck(caller.userId);
    assertAllowed(gate);
    if (gate.tier !== "premium") throw new AppError("premium_required");

    const db = adminClient();
    const { data: result, error: rpcErr } = await db.rpc("retention_simulate_rpc", {
      p_user: caller.userId,
    });
    if (rpcErr) throw rpcErr;

    return jsonResponse(result);
  } catch (err) {
    console.error("retention-simulate error:", (err as Error)?.message);
    return toErrorResponse(err);
  }
});
