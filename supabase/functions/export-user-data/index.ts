// export-user-data [S24]. POST (user JWT). Builds a single zip of the caller's
// data and returns a short-lived signed download URL. One file per user: each
// generate overwrites exports/{user_id}/recall-export.zip and resets the 12h TTL
// (user_exports ledger). The hourly cleanup-exports cron prunes expired files.
//   body { action?: "generate" | "status" }   (default "generate")
//   -> { status: "ready", signed_url, url_expires_at, file_expires_at,
//        generated_at }  |  { status: "none" }
// Inner JSON schemas are pinned in CANON-DECISIONS.md [D-EF-5].
// Contents: profile, buckets, nodes, reviews, tags, quiz_attempts, and the
// Ask Aura transcript (ai_conversations + ai_messages).

import JSZip from "https://esm.sh/jszip@3.10.1";
import { handlePreflight } from "../_shared/cors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { adminClient } from "../_shared/supabase.ts";

const BUCKET = "exports";
const FILE_NAME = "recall-export.zip";
// File lives 12h (cron-pruned); the download URL is short-lived and re-minted on
// demand via the "status" action.
const FILE_TTL_MS = 12 * 60 * 60 * 1000;
const URL_TTL_SECONDS = 60 * 60;

// AI counters are excluded from profile.json [D-EF-5] / [D-AI-2].
const PROFILE_OMIT = ["ai_requests_month", "ai_overviews_month", "ai_usage_period"];

function storagePath(userId: string): string {
  return `${userId}/${FILE_NAME}`;
}

async function signedUrl(
  db: ReturnType<typeof adminClient>,
  path: string,
): Promise<string | null> {
  const { data, error } = await db.storage
    .from(BUCKET)
    .createSignedUrl(path, URL_TTL_SECONDS);
  if (error || !data?.signedUrl) return null;
  return data.signedUrl;
}

/** Re-mint a URL for an existing, non-expired export, else report "none". */
async function exportStatus(
  db: ReturnType<typeof adminClient>,
  userId: string,
): Promise<Response> {
  const { data: row } = await db
    .from("user_exports")
    .select("storage_path, expires_at")
    .eq("user_id", userId)
    .maybeSingle();

  if (!row || new Date(row.expires_at).getTime() <= Date.now()) {
    return jsonResponse({ status: "none" });
  }
  const url = await signedUrl(db, row.storage_path);
  if (!url) return jsonResponse({ status: "none" });

  return jsonResponse({
    status: "ready",
    signed_url: url,
    url_expires_at: new Date(Date.now() + URL_TTL_SECONDS * 1000).toISOString(),
    file_expires_at: row.expires_at,
  });
}

/** Build the zip, overwrite the user's single export, reset the TTL, sign it. */
async function generateExport(
  db: ReturnType<typeof adminClient>,
  userId: string,
): Promise<Response> {
  // profile.json — every column except the internal AI counters.
  const { data: profile, error: pErr } = await db
    .from("profiles")
    .select("*")
    .eq("id", userId)
    .single();
  if (pErr) throw pErr;
  const profileOut: Record<string, unknown> = { ...profile };
  for (const k of PROFILE_OMIT) delete profileOut[k];

  const { data: buckets, error: bErr } = await db
    .from("buckets")
    .select("id, name, cooling_period, frequency, daily_cap, created_at")
    .eq("user_id", userId);
  if (bErr) throw bErr;

  // Keyed on nodes.user_id rather than the bucket list, so a note that belongs
  // to no bucket is still the user's and still leaves in their export.
  const { data: nodeRows, error: nErr } = await db
    .from("nodes")
    .select(
      "id, bucket_id, type, title, markdown, url, link_preview_json, priority, difficulty, comfort, stability, due_at, reps, lapses, state, created_at, updated_at",
    )
    .eq("user_id", userId);
  if (nErr) throw nErr;
  const nodes = nodeRows ?? [];

  const { data: reviews, error: rErr } = await db
    .from("reviews")
    .select("id, node_id, grade, reviewed_at, response_ms, source")
    .eq("user_id", userId);
  if (rErr) throw rErr;

  const { data: tags, error: tErr } = await db
    .from("tags")
    .select("id, name")
    .eq("user_id", userId);
  if (tErr) throw tErr;

  const { data: quizAttempts, error: qErr } = await db
    .from("quiz_attempts")
    .select("id, mode, question_type, score_pct, question_count, completed_at")
    .eq("user_id", userId);
  if (qErr) throw qErr;

  // Ask Aura transcripts are the user's own words and belong in the export.
  const { data: conversations, error: cErr } = await db
    .from("ai_conversations")
    .select("id, title, scope, created_at, last_message_at, archived_at")
    .eq("user_id", userId);
  if (cErr) throw cErr;

  const conversationIds = (conversations ?? []).map((c) => c.id as string);
  let messages: unknown[] = [];
  if (conversationIds.length > 0) {
    const { data, error } = await db
      .from("ai_messages")
      .select("id, conversation_id, role, content, citations, created_at")
      .in("conversation_id", conversationIds)
      .order("created_at", { ascending: true });
    if (error) throw error;
    messages = data ?? [];
  }

  const zip = new JSZip();
  const stamp = (v: unknown) => JSON.stringify(v ?? [], null, 2);
  zip.file("profile.json", JSON.stringify(profileOut, null, 2));
  zip.file("buckets.json", stamp(buckets));
  zip.file("nodes.json", stamp(nodes));
  zip.file("reviews.json", stamp(reviews));
  zip.file("tags.json", stamp(tags));
  zip.file("quiz_attempts.json", stamp(quizAttempts));
  zip.file("ai_conversations.json", stamp(conversations));
  zip.file("ai_messages.json", stamp(messages));

  const bytes = await zip.generateAsync({ type: "uint8array" });
  const path = storagePath(userId);

  const { error: upErr } = await db.storage
    .from(BUCKET)
    .upload(path, bytes, { contentType: "application/zip", upsert: true });
  if (upErr) throw upErr;

  const now = Date.now();
  const expiresAt = new Date(now + FILE_TTL_MS).toISOString();
  const generatedAt = new Date(now).toISOString();

  const { error: ledgerErr } = await db
    .from("user_exports")
    .upsert(
      { user_id: userId, storage_path: path, created_at: generatedAt, expires_at: expiresAt },
      { onConflict: "user_id" },
    );
  if (ledgerErr) throw ledgerErr;

  const url = await signedUrl(db, path);
  if (!url) throw new AppError("provider_error", "Could not sign the export URL.");

  return jsonResponse({
    status: "ready",
    signed_url: url,
    url_expires_at: new Date(now + URL_TTL_SECONDS * 1000).toISOString(),
    file_expires_at: expiresAt,
    generated_at: generatedAt,
  });
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    if (!caller.userId) throw new AppError("unauthorized");

    let action = "generate";
    try {
      const body = await req.json();
      if (body && typeof body.action === "string") action = body.action;
    } catch {
      // empty body → default action
    }

    const db = adminClient();
    if (action === "status") return await exportStatus(db, caller.userId);
    if (action === "generate") return await generateExport(db, caller.userId);
    throw new AppError("invalid_input", "Unknown action.");
  } catch (err) {
    console.error("export-user-data error:", (err as Error)?.message);
    return toErrorResponse(err);
  }
});
