// embed-drain — works the ai_embed_queue. Cron-driven (pg_cron every minute) and
// also nudged by the nodes.content_hash trigger so a saved note is usually
// embedded within seconds. Authenticated by X-Cron-Secret, never a user JWT.
//
// The queue is what makes embedding durable: previously the trigger fired a bare
// pg_net POST, and if that was lost the note was silently never searchable. Here
// a claimed item is only marked done once its chunks are written, and anything
// that fails is retried with backoff until it succeeds or lands in a visible
// 'failed' state.
//
// Claims use FOR UPDATE SKIP LOCKED, so the cron tick and a trigger nudge
// arriving together share the work instead of duplicating it.

import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";
import { AppConfig } from "../_shared/config.ts";
import { embedNode } from "../_shared/embed_node.ts";

interface QueueItem {
  id: number;
  source_kind: string;
  source_id: string;
  reason: "content_change" | "reindex";
  attempts: number;
}

/** Constant-time compare so the secret cannot be recovered by timing. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  const expected = Deno.env.get("CRON_SECRET") ?? "";
  const provided = req.headers.get("X-Cron-Secret") ?? "";
  if (!expected || !safeEqual(provided, expected)) {
    return jsonResponse({ error: "unauthorized", message: "Invalid cron secret." }, 401);
  }

  const db = adminClient();
  const config = await AppConfig.load();

  const { data, error } = await db.rpc("ai_embed_claim", {
    p_limit: config.int("ai_embed_batch_limit", 25),
  });
  if (error) {
    console.error("ai_embed_claim failed:", error);
    return jsonResponse({ error: "provider_error", message: error.message }, 503);
  }

  const items = (data ?? []) as QueueItem[];
  let embedded = 0;
  let skipped = 0;
  let failed = 0;

  for (const item of items) {
    // Per-item try/catch: one bad note must not abandon the rest of the batch,
    // and every path has to report back or the item stays claimed until reclaim.
    try {
      if (item.source_kind !== "node") {
        await complete(item.id, false, `unsupported source_kind "${item.source_kind}"`);
        failed++;
        continue;
      }

      // A reindex rebuilds vectors for content the user already paid to embed,
      // so it must not be charged again.
      const result = await embedNode(item.source_id, config, {
        meter: item.reason !== "reindex",
        reason: item.reason,
      });
      await complete(item.id, true);
      if (result.skipped) skipped++;
      else embedded++;
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      console.error(
        `embed failed for ${item.source_kind} ${item.source_id} (attempt ${item.attempts + 1}):`,
        message,
      );
      await complete(item.id, false, message);
      failed++;
    }
  }

  return jsonResponse({ claimed: items.length, embedded, skipped, failed });
});

async function complete(id: number, ok: boolean, errorMessage?: string): Promise<void> {
  const { error } = await adminClient().rpc("ai_embed_complete", {
    p_id: id,
    p_ok: ok,
    p_error: errorMessage ?? null,
  });
  // The reclaim window is the safety net, so this must not mask the real outcome.
  if (error) console.error("ai_embed_complete failed:", error.message);
}
