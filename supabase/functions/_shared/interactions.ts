// Training-aligned data foundation [D-AI-6]. Every AI feature logs a STRUCTURED
// interaction row; full prompt/context/answer text is included only when the
// user opted in or the AI_CAPTURE_FULL_TEXT env flag is on (the RPC enforces
// this). Logging must never break the AI response path — it swallows errors.

import { adminClient } from "./supabase.ts";

export type Blend = "notes_only" | "blended" | "general_only";

export interface LogInteractionInput {
  userId: string;
  feature: string;
  scope?: Record<string, unknown>;
  retrievedNodeIds?: string[];
  hadNotes?: boolean;
  blend?: Blend | null;
  model?: string | null;
  latencyMs?: number | null;
  inputTokens?: number;
  outputTokens?: number;
  payload?: Record<string, unknown> | null;
  contentHash?: string | null;
  // Phase 8 capture fields (all optional).
  requestId?: string | null;
  promptId?: string | null;
  promptVersion?: string | null;
  systemPromptSha?: string | null;
  provider?: string | null;
  providerRequestId?: string | null;
  temperature?: number | null;
  maxTokens?: number | null;
  scopeKind?: string | null;
  retrievalMode?: string | null;
  conversationId?: string | null;
  errorCode?: string | null;
  retentionUntil?: string | null;
}

/** Global capture switch (per-user opt-in is enforced inside the RPC). */
export function captureFullText(): boolean {
  return (Deno.env.get("AI_CAPTURE_FULL_TEXT") ?? "").toLowerCase() === "true";
}

/** Append a structured interaction; returns its id (or null on failure). */
export async function logInteraction(input: LogInteractionInput): Promise<string | null> {
  try {
    const { data, error } = await adminClient().rpc("ai_log_interaction", {
      p_user: input.userId,
      p_feature: input.feature,
      p_scope: input.scope ?? {},
      p_retrieved: input.retrievedNodeIds ?? [],
      p_had_notes: input.hadNotes ?? false,
      p_blend: input.blend ?? null,
      p_model: input.model ?? null,
      p_latency_ms: input.latencyMs ?? null,
      p_input: input.inputTokens ?? 0,
      p_output: input.outputTokens ?? 0,
      p_payload: input.payload ?? null,
      p_content_hash: input.contentHash ?? null,
      p_global_capture: captureFullText(),
      p_request_id: input.requestId ?? null,
      p_prompt_id: input.promptId ?? null,
      p_prompt_version: input.promptVersion ?? null,
      p_system_prompt_sha: input.systemPromptSha ?? null,
      p_provider: input.provider ?? null,
      p_provider_request_id: input.providerRequestId ?? null,
      p_temperature: input.temperature ?? null,
      p_max_tokens: input.maxTokens ?? null,
      p_scope_kind: input.scopeKind ?? null,
      p_retrieval_mode: input.retrievalMode ?? null,
      p_conversation_id: input.conversationId ?? null,
      p_error_code: input.errorCode ?? null,
      p_retention_until: input.retentionUntil ?? null,
    });
    if (error) {
      console.error("ai_log_interaction failed:", error.message);
      return null;
    }
    return (data as string) ?? null;
  } catch (e) {
    console.error("ai_log_interaction threw:", (e as Error).message);
    return null;
  }
}

/**
 * Log a failed generation after settle(failed). Best-effort — never throws.
 * Use from withMeteredRequest catch paths so rejected answers still enter the
 * training spine (error_code set, payload optional).
 */
export async function logFailedInteraction(
  input: Omit<LogInteractionInput, "payload"> & {
    errorCode: string;
    payload?: Record<string, unknown> | null;
  },
): Promise<string | null> {
  return logInteraction({
    ...input,
    hadNotes: input.hadNotes ?? false,
    errorCode: input.errorCode,
    payload: input.payload ?? { error: input.errorCode },
  });
}
