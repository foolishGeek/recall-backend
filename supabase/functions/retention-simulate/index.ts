/// <reference lib="deno.ns" />

// retention-simulate [S21]. POST (no body) -> 90-day forgetting-curve payload.
// Premium-only in canon. While `app_config.limits_profile = "relaxed"` (payments
// settling), free/downgraded may also call — powers Insights + You simulation.
// Owns auth + gating + profile cache write via retention_simulate_rpc.
// Shape: { retention_with_recall, retention_baseline, curve_points[],
//   is_projected, review_days_count, memories_saved }

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { assertAllowed, gateCheck } from "../_shared/quota.ts";
import { AppConfig } from "../_shared/config.ts";
import { adminClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId) throw new AppError("unauthorized");

    // Blocks maintenance / kill-switch; premium check follows.
    const gate = await gateCheck(caller.userId);
    assertAllowed(gate);

    if (gate.tier !== "premium") {
      const config = await AppConfig.load();
      const profile = config.str("limits_profile", "canon");
      if (profile !== "relaxed") throw new AppError("premium_required");
    }

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
