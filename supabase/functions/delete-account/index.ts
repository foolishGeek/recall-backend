// delete-account [S24]. POST (user JWT). Irreversibly removes the caller's
// account. Server success is required before the app signs out, so we run the
// non-cascading cleanup first, then auth.admin.deleteUser (which cascades the
// profile + every child table):
//   1. RevenueCat REST "delete subscriber" (best-effort) [D-EF-7]
//   2. Purge Storage {user_id}/ in node-pdfs / node-images / exports
//   3. Delete non-cascading rows (revenuecat_events, user_exports)
//   4. auth.admin.deleteUser(userId) -> cascade
//   -> { deleted: true }

import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";

const STORAGE_BUCKETS = ["node-pdfs", "node-images", "exports"];
const RC_BASE = "https://api.revenuecat.com/v1/subscribers";

/** Best-effort RevenueCat subscriber delete; a billing hiccup never blocks the
 *  account deletion. */
async function deleteRevenueCatSubscriber(userId: string): Promise<void> {
  const key = Deno.env.get("REVENUECAT_REST_API_KEY");
  if (!key) {
    console.warn("delete-account: REVENUECAT_REST_API_KEY not set; skipping RC delete");
    return;
  }
  try {
    const res = await fetch(`${RC_BASE}/${encodeURIComponent(userId)}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${key}` },
    });
    if (!res.ok && res.status !== 404) {
      console.warn(`delete-account: RC delete returned ${res.status}`);
    }
  } catch (e) {
    console.warn("delete-account: RC delete failed (ignored):", (e as Error)?.message);
  }
}

/** Recursively collects every object path under a prefix (storage.list only
 *  returns immediate children; folders have a null id). */
async function collectPaths(
  db: ReturnType<typeof adminClient>,
  bucket: string,
  prefix: string,
): Promise<string[]> {
  const out: string[] = [];
  const { data, error } = await db.storage.from(bucket).list(prefix, { limit: 1000 });
  if (error || !data) return out;
  for (const item of data) {
    const path = prefix ? `${prefix}/${item.name}` : item.name;
    if (item.id === null) {
      out.push(...(await collectPaths(db, bucket, path)));
    } else {
      out.push(path);
    }
  }
  return out;
}

async function purgeStorage(
  db: ReturnType<typeof adminClient>,
  userId: string,
): Promise<void> {
  for (const bucket of STORAGE_BUCKETS) {
    const paths = await collectPaths(db, bucket, userId);
    if (paths.length === 0) continue;
    const { error } = await db.storage.from(bucket).remove(paths);
    if (error) {
      console.warn(`delete-account: storage purge (${bucket}) failed:`, error.message);
    }
  }
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId) throw new AppError("unauthorized");
    const userId = caller.userId;
    const db = adminClient();

    await deleteRevenueCatSubscriber(userId);
    await purgeStorage(db, userId);

    // Non-cascading audit rows (no FK to auth.users / profiles).
    await db.from("revenuecat_events").delete().eq("app_user_id", userId);
    await db.from("user_exports").delete().eq("user_id", userId);

    const { error: delErr } = await db.auth.admin.deleteUser(userId);
    if (delErr) throw new AppError("provider_error", delErr.message);

    return jsonResponse({ deleted: true });
  } catch (err) {
    console.error("delete-account error:", (err as Error)?.message);
    return toErrorResponse(err);
  }
});
