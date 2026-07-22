// compute-due — Recall Drop pipeline (S16). Cron-driven (pg_cron every 5 min),
// authenticated by the X-Cron-Secret header (no user JWT). All Drop-trigger
// logic lives in compute_due_candidates() (SQL, service role); this function
// only performs FCM I/O, logs 'sent'/'failed', and prunes dead tokens.
// FCM data payload: { type:'recall_drop', route:'/today', dedupe_key }.
// Reliability: a real delivery logs 'sent' (claims the dedupe slot / advances the
// watermark); an all-tokens-transient failure logs 'failed' for audit WITHOUT
// claiming 'sent', so the user re-qualifies on the next tick.
// Spec: Roadmap/sprints/S16-notifications.md · [D-EF-9] [D-EF-10] [D-EF-8].

import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";
import { sendDrop } from "../_shared/fcm.ts";

interface Candidate {
  user_id: string;
  dedupe_key: string;
  due_pool_size: number;
  tokens: { platform: string; token: string }[];
}

/** Constant-time string compare to avoid leaking the secret via timing. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  // Auth: cron secret only — never run logic on mismatch (S16 §6).
  const expected = Deno.env.get("CRON_SECRET") ?? "";
  const provided = req.headers.get("X-Cron-Secret") ?? "";
  if (!expected || !safeEqual(provided, expected)) {
    return new Response(
      JSON.stringify({ error: "unauthorized", message: "Invalid cron secret." }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const supabase = adminClient();

  const { data, error } = await supabase.rpc("compute_due_candidates");
  if (error) {
    console.error("compute_due_candidates failed:", error);
    return jsonResponse({ error: "provider_error", message: error.message }, 503);
  }

  const candidates = (data ?? []) as Candidate[];
  let notificationsSent = 0;
  let notificationsFailed = 0;

  for (const candidate of candidates) {
    // Per-user try/catch so one failure can't abort the batch (S16 §7).
    try {
      const payload: Record<string, string> = {
        type: "recall_drop",
        route: "/today",
        dedupe_key: candidate.dedupe_key,
      };

      let anySuccess = false;
      let transientFailure = false;
      const staleTokens: string[] = [];

      for (const device of candidate.tokens ?? []) {
        const result = await sendDrop(device.token, payload);
        if (result.ok) anySuccess = true;
        if (result.prune) staleTokens.push(device.token);
        // Not delivered and not a dead token => a transient/provider failure.
        if (!result.ok && !result.prune) transientFailure = true;
      }

      // Prune unregistered tokens regardless of overall send outcome.
      if (staleTokens.length > 0) {
        await supabase
          .from("device_tokens")
          .delete()
          .eq("user_id", candidate.user_id)
          .in("token", staleTokens);
      }

      // Only log 'sent' on a real delivery — a permanent failure must NOT
      // claim the dedupe_key, or it would suppress a future real Drop.
      if (anySuccess) {
        const { error: logError } = await supabase
          .from("notification_events")
          .upsert(
            {
              user_id: candidate.user_id,
              type: "sent",
              dedupe_key: candidate.dedupe_key,
              metadata: { due_pool_size: candidate.due_pool_size },
            },
            { onConflict: "dedupe_key,type", ignoreDuplicates: true },
          );
        if (logError) {
          console.error(`log sent failed for ${candidate.user_id}:`, logError);
        } else {
          notificationsSent++;
        }
      } else if (transientFailure) {
        // Audit the transient failure without claiming the 'sent' dedupe slot,
        // so the watermark does not advance and the user retries next tick.
        const { error: failError } = await supabase
          .from("notification_events")
          .upsert(
            {
              user_id: candidate.user_id,
              type: "failed",
              dedupe_key: candidate.dedupe_key,
              metadata: { due_pool_size: candidate.due_pool_size },
            },
            { onConflict: "dedupe_key,type", ignoreDuplicates: true },
          );
        if (failError) {
          console.error(`log failed for ${candidate.user_id}:`, failError);
        }
        notificationsFailed++;
      }
    } catch (e) {
      console.error(`compute-due user ${candidate.user_id} failed:`, e);
    }
  }

  return jsonResponse({
    users_evaluated: candidates.length,
    notifications_sent: notificationsSent,
    notifications_failed: notificationsFailed,
  });
});
