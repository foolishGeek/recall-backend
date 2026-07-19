// Premium feature access: paid premium, or temporary-free while
// `app_config.limits_profile = "relaxed"`. Quiz stays premium-only (client WIP).
// Flip back with SQL `rollback_limits_to_canon()` — no app release.

import { AppConfig } from "./config.ts";
import { AppError } from "./errors.ts";

/** Throws premium_required unless tier is premium or limits_profile is relaxed. */
export async function assertPremiumAccess(
  tier: string | undefined,
  config?: AppConfig,
): Promise<void> {
  if (tier === "premium") return;
  const cfg = config ?? await AppConfig.load();
  if (cfg.str("limits_profile", "canon") === "relaxed") return;
  throw new AppError("premium_required");
}

/** True when temporary free is active (payments settling). */
export async function isLimitsRelaxed(config?: AppConfig): Promise<boolean> {
  const cfg = config ?? await AppConfig.load();
  return cfg.str("limits_profile", "canon") === "relaxed";
}
