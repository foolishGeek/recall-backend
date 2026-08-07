// extract-asset-text — stub. Verifies the caller owns the asset, then marks
-- parse_status = 'unsupported' until a real extractor lands. Returns JSON so
-- mobile can poll without treating the stub as a hard failure.

import { handlePreflight } from "../_shared/cors.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireUuid } from "../_shared/validate.ts";

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId && !caller.isServiceRole) throw new AppError("unauthorized");

    const body = await req.json().catch(() => ({}));
    const assetId = requireUuid((body as { asset_id?: string }).asset_id, "asset_id");
    const db = adminClient();

    // Prefer nodes.user_id; fall back to buckets join for safety during rollout.
    const { data: asset, error } = await db
      .from("node_assets")
      .select("id, node_id, mime_type, parse_status, nodes!inner(id, user_id, bucket_id, buckets(user_id))")
      .eq("id", assetId)
      .maybeSingle();
    if (error) throw error;
    if (!asset) throw new AppError("invalid_input", "asset not found");

    const node = (asset as {
      nodes?: { user_id?: string; buckets?: { user_id?: string } };
    }).nodes;
    const owner = node?.user_id ?? node?.buckets?.user_id;
    if (caller.userId && owner !== caller.userId) throw new AppError("unauthorized");

    const { error: updErr } = await db
      .from("node_assets")
      .update({ parse_status: "unsupported" })
      .eq("id", assetId);
    if (updErr) throw updErr;

    return jsonResponse({
      asset_id: assetId,
      parse_status: "unsupported",
      message: "Asset text extraction is not implemented yet.",
    });
  } catch (err) {
    return toErrorResponse(err);
  }
});
