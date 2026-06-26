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
