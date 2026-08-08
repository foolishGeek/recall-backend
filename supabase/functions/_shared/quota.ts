// The AI gate. Every entitlement and quota decision comes from ai_feature_policy
// (migration 00060) via these RPCs — Edge Functions never decide, and there is
// no per-feature branching here either.
//
// Charging is reserve -> settle. `withMeteredRequest` is the only way a feature
// should run billable work: it holds a unit before the model call and settles
// after, releasing the hold on any failure. A refund would not be enough,
// because if the isolate is killed the refund never runs; the reservation has a
// deadline and the ai_sweep_stale_requests cron releases it instead.

import { adminClient } from "./supabase.ts";
import { AppError, ErrorCode } from "./errors.ts";
import { logFailedInteraction } from "./interactions.ts";

export type Tier = "free" | "premium";

export interface GateDecision {
  allowed: boolean;
  tier?: Tier;
  error?: ErrorCode;
  message?: string;
  cooldown_until?: string;
  request_id?: string;
  temperature?: number;
  max_tokens?: number;
  replay?: boolean;
  response?: unknown;
}

/**
 * Credit intent for the premium fair-use cooldown path:
 * - "auto"  -> deduct a credit if available, else 429 ai_cooldown (default).
 * - "ask"   -> never spend; always 429 ai_cooldown so the UI can ask first.
 * - "spend" -> explicit spend; deduct, or 403 insufficient_credits at balance 0.
 */
export type CreditIntent = "auto" | "ask" | "spend";

/** Maintenance / entitlement pre-flight for one feature. No mutation. */
export async function gateCheck(
  userId: string,
  feature?: string,
): Promise<GateDecision> {
  const { data, error } = await adminClient().rpc("ai_gate_check", {
    p_user: userId,
    p_feature: feature ?? null,
  });
  if (error) throw error;
  return data as GateDecision;
}

/** Throws the mapped AppError when a gate decision is a denial. */
export function assertAllowed(d: GateDecision): void {
  if (d.allowed) return;
  const code = (d.error ?? "provider_error") as ErrorCode;
  const extra = d.cooldown_until
    ? { cooldown_until: d.cooldown_until }
    : undefined;
  throw new AppError(code, d.message, extra);
}

export interface MeterInput {
  userId: string;
  feature: string;
  creditIntent?: CreditIntent;
  /** Client-supplied idempotency key; a retry replays instead of re-charging. */
  clientRequestId?: string | null;
  conversationId?: string | null;
}

/** What the reservation grants the feature: its tier and its sampling settings. */
export interface Reservation {
  requestId: string | null;
  tier: Tier;
  temperature?: number;
  maxTokens?: number;
}

/** What a feature reports back so the ledger can record the real cost. */
export interface MeteredOutcome<T> {
  result: T;
  model?: string | null;
  provider?: string | null;
  inputTokens?: number;
  outputTokens?: number;
  /** Cached for idempotent replay of a retried request; cleared after 6h. */
  cacheResponse?: boolean;
}

async function reserve(input: MeterInput): Promise<GateDecision> {
  const { data, error } = await adminClient().rpc("ai_gate_reserve", {
    p_user: input.userId,
    p_feature: input.feature,
    p_credit_intent: input.creditIntent ?? "auto",
    p_client_request_id: input.clientRequestId ?? null,
    p_conversation_id: input.conversationId ?? null,
  });
  if (error) throw error;
  return data as GateDecision;
}

async function settle(
  requestId: string,
  status: "succeeded" | "failed",
  fields: {
    model?: string | null;
    provider?: string | null;
    inputTokens?: number;
    outputTokens?: number;
    latencyMs?: number | null;
    errorCode?: string | null;
    response?: unknown;
  } = {},
): Promise<void> {
  const { error } = await adminClient().rpc("ai_gate_settle", {
    p_request: requestId,
    p_status: status,
    p_model: fields.model ?? null,
    p_provider: fields.provider ?? null,
    p_input: fields.inputTokens ?? 0,
    p_output: fields.outputTokens ?? 0,
    p_latency_ms: fields.latencyMs ?? null,
    p_error_code: fields.errorCode ?? null,
    p_response: fields.response ?? null,
  });
  // Settling must never mask the real outcome; the sweeper is the safety net.
  if (error) console.error("ai_gate_settle failed:", error.message);
}

/**
 * A held unit of quota, closed by exactly one of `succeeded` / `failed`.
 *
 * Streaming needs the reservation and the response to be separable: the quota
 * decision has to happen before the first byte (a denial must be a JSON 403, not
 * an error buried in an event stream), while the cost is only known once the
 * stream ends. `withMeteredRequest` is this same object with the try/catch
 * written for it.
 */
export interface MeteredHold {
  reservation: Reservation;
  /** Set when the client's idempotency key matched a cached response. */
  replay?: unknown;
  succeeded(out: Omit<MeteredOutcome<unknown>, "result"> & { result?: unknown }): Promise<void>;
  failed(err: unknown): Promise<void>;
}

/**
 * Reserves a unit and returns the hold. Denials raise the mapped AppError, so
 * callers can treat a returned hold as permission to spend.
 */
export async function openMeteredRequest(input: MeterInput): Promise<MeteredHold> {
  const decision = await reserve(input);
  if (decision.replay) {
    return {
      replay: decision.response,
      reservation: { requestId: null, tier: decision.tier ?? "free" },
      succeeded: () => Promise.resolve(),
      failed: () => Promise.resolve(),
    };
  }
  assertAllowed(decision);

  const requestId = decision.request_id ?? null;
  const startedAt = Date.now();
  let closed = false;

  return {
    reservation: {
      requestId,
      tier: decision.tier ?? "free",
      temperature: decision.temperature,
      maxTokens: decision.max_tokens,
    },
    async succeeded(out) {
      if (closed) return;
      closed = true;
      if (!requestId) return;
      await settle(requestId, "succeeded", {
        model: out.model,
        provider: out.provider,
        inputTokens: out.inputTokens,
        outputTokens: out.outputTokens,
        latencyMs: Date.now() - startedAt,
        response: out.cacheResponse ? out.result : null,
      });
    },
    async failed(err) {
      if (closed) return;
      closed = true;
      const errorCode = err instanceof AppError ? err.code : "provider_error";
      if (requestId) {
        await settle(requestId, "failed", { latencyMs: Date.now() - startedAt, errorCode });
      }
      // Capture failed generations so rejected answers still enter the spine.
      await logFailedInteraction({
        userId: input.userId,
        feature: input.feature,
        requestId,
        conversationId: input.conversationId ?? null,
        errorCode,
        latencyMs: Date.now() - startedAt,
      });
    },
  };
}

async function run<T>(
  hold: MeteredHold,
  work: (r: Reservation) => Promise<MeteredOutcome<T>>,
): Promise<T> {
  try {
    const out = await work(hold.reservation);
    await hold.succeeded(out);
    return out.result;
  } catch (err) {
    await hold.failed(err);
    throw err;
  }
}

/**
 * Runs billable work under a reservation. The user is charged only if `work`
 * returns; any throw releases the hold. Denials raise the mapped AppError.
 */
export async function withMeteredRequest<T>(
  input: MeterInput,
  work: (r: Reservation) => Promise<MeteredOutcome<T>>,
): Promise<T> {
  const hold = await openMeteredRequest(input);
  if (hold.replay !== undefined) return hold.replay as T;
  return run(hold, work);
}

/**
 * Same guarantee, but a denial yields null instead of an error — for internal
 * work like `embed`, which is skipped silently when the owner is out of quota
 * rather than surfacing an error the user never asked for [D-AI-3].
 */
export async function withOptionalMeteredRequest<T>(
  input: MeterInput,
  work: (r: Reservation) => Promise<MeteredOutcome<T>>,
): Promise<T | null> {
  let hold: MeteredHold;
  try {
    hold = await openMeteredRequest(input);
  } catch (err) {
    // A denial is the expected quiet outcome here; anything else is a real fault.
    if (err instanceof AppError) return null;
    throw err;
  }
  if (hold.replay !== undefined) return hold.replay as T;
  return run(hold, work);
}
