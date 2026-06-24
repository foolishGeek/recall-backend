// Canonical error taxonomy [CANON §11] for Edge Functions. Every non-2xx body
// is { error, message, ...extra } so the client maps it to a typed RepoException.

import { corsHeaders } from "./cors.ts";

export type ErrorCode =
  | "invalid_input"
  | "unauthorized"
  | "premium_required"
  | "ai_quota_exceeded"
  | "overview_quota_exceeded"
  | "insufficient_credits"
  | "free_tier_bucket_limit"
  | "free_tier_stack_limit"
  | "empty_context"
  | "ai_cooldown"
  | "maintenance"
  | "provider_error";

const STATUS: Record<ErrorCode, number> = {
  invalid_input: 400,
  unauthorized: 401,
  premium_required: 403,
  ai_quota_exceeded: 403,
  overview_quota_exceeded: 403,
  insufficient_credits: 403,
  free_tier_bucket_limit: 403,
  free_tier_stack_limit: 403,
  empty_context: 422,
  ai_cooldown: 429,
  maintenance: 503,
  provider_error: 503,
};

const DEFAULT_MESSAGE: Record<ErrorCode, string> = {
  invalid_input: "Bad or missing payload.",
  unauthorized: "Missing or invalid credentials.",
  premium_required: "This feature needs an active premium subscription.",
  ai_quota_exceeded: "You've used all your AI requests this month.",
  overview_quota_exceeded: "You've used all your AI overviews this month.",
  insufficient_credits: "You don't have enough AI credits.",
  free_tier_bucket_limit: "Free plan bucket limit reached.",
  free_tier_stack_limit: "Free plan stack limit reached.",
  empty_context: "There's no content to work with here.",
  ai_cooldown: "Taking a short break — try again later.",
  maintenance: "AI is temporarily unavailable.",
  provider_error: "The AI provider failed to respond. Try again.",
};

/** Typed error that carries an [CANON §11] code + optional structured extra. */
export class AppError extends Error {
  code: ErrorCode;
  extra?: Record<string, unknown>;

  constructor(code: ErrorCode, message?: string, extra?: Record<string, unknown>) {
    super(message ?? DEFAULT_MESSAGE[code]);
    this.code = code;
    this.extra = extra;
  }
}

/** Builds a JSON error Response with the mapped HTTP status + CORS headers. */
export function errorResponse(
  code: ErrorCode,
  message?: string,
  extra?: Record<string, unknown>,
): Response {
  return new Response(
    JSON.stringify({ error: code, message: message ?? DEFAULT_MESSAGE[code], ...extra }),
    {
      status: STATUS[code],
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
}

/** Success JSON Response with CORS headers. */
export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Maps a thrown value to an error Response (AppError → mapped, else 503). */
export function toErrorResponse(err: unknown): Response {
  if (err instanceof AppError) {
    return errorResponse(err.code, err.message, err.extra);
  }
  console.error("Unhandled edge function error:", err);
  return errorResponse("provider_error", "Unexpected server error.");
}
