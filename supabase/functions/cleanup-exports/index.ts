// cleanup-exports [S24]. Cron-driven (pg_cron hourly via invoke_cleanup_exports,
// 00027), authenticated by the X-Cron-Secret header (no user JWT). Removes export
// zips past their 12h TTL — storage objects cannot be deleted from SQL, so the
// ledger sweep happens here. -> { removed: N }.

import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";

const BUCKET = "exports";

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

  const expected = Deno.env.get("CRON_SECRET") ?? "";
  const provided = req.headers.get("X-Cron-Secret") ?? "";
  if (!expected || !safeEqual(provided, expected)) {
    return new Response(
      JSON.stringify({ error: "unauthorized", message: "Invalid cron secret." }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const db = adminClient();

  const { data: expired, error } = await db
    .from("user_exports")
    .select("user_id, storage_path")
    .lte("expires_at", new Date().toISOString());
  if (error) {
    console.error("cleanup-exports: select failed:", error.message);
    return jsonResponse({ error: "provider_error", message: error.message }, 503);
  }

  const rows = expired ?? [];
  if (rows.length === 0) return jsonResponse({ removed: 0 });

  const paths = rows.map((r) => r.storage_path as string);
  const { error: rmErr } = await db.storage.from(BUCKET).remove(paths);
  if (rmErr) console.warn("cleanup-exports: storage remove failed:", rmErr.message);

  const userIds = rows.map((r) => r.user_id as string);
  const { error: delErr } = await db
    .from("user_exports")
    .delete()
    .in("user_id", userIds);
  if (delErr) console.warn("cleanup-exports: ledger delete failed:", delErr.message);

  return jsonResponse({ removed: rows.length });
});
