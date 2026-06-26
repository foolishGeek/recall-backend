// Thin wrappers over the §3b gate RPCs (migration 00005). The gate is the single
// source of truth for AI quota/credit/cooldown; Edge Functions never decide.

import { adminClient } from "./supabase.ts";
import { AppError, ErrorCode } from "./errors.ts";

export interface GateDecision {
  allowed: boolean;
  tier?: "free" | "premium";
  error?: ErrorCode;
  cooldown_until?: string;
}

/** Maintenance + downgrade pre-flight (no mutation). */
export async function gateCheck(userId: string): Promise<GateDecision> {
  const { data, error } = await adminClient().rpc("ai_gate_check", { p_user: userId });
  if (error) throw error;
  return data as GateDecision;
}

/**
 * Credit intent for the premium fair-use cooldown path:
 * - "auto"  -> deduct a credit if available, else 429 ai_cooldown (default).
 * - "ask"   -> never spend; always 429 ai_cooldown so the UI can ask first.
 * - "spend" -> explicit spend; deduct, or 403 insufficient_credits at balance 0.
 */
export type CreditIntent = "auto" | "ask" | "spend";

/** Full §3b gate; mutates counters/credits atomically on allow. */
export async function gateConsume(
  userId: string,
  feature: string,
  intent: CreditIntent = "auto",
): Promise<GateDecision> {
  const { data, error } = await adminClient().rpc("ai_gate_consume", {
    p_user: userId,
    p_feature: feature,
    p_credit_intent: intent,
  });
  if (error) throw error;
  return data as GateDecision;
}

/** Throws the mapped AppError when a gate decision is a denial. */
export function assertAllowed(d: GateDecision): void {
  if (d.allowed) return;
  const code = (d.error ?? "provider_error") as ErrorCode;
  const extra = d.cooldown_until ? { cooldown_until: d.cooldown_until } : undefined;
  throw new AppError(code, undefined, extra);
}

/** Append token accounting to ai_usage. */
export async function logUsage(
  userId: string,
  feature: string,
  inputTokens: number,
  outputTokens: number,
  model: string | null,
): Promise<void> {
  const { error } = await adminClient().rpc("ai_log_usage", {
    p_user: userId,
    p_feature: feature,
    p_input: inputTokens,
    p_output: outputTokens,
    p_model: model,
  });
  if (error) console.error("ai_log_usage failed:", error.message);
}
