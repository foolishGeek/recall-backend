// extract-pdf-text [D-EF-1]. POST { storage_path } → { extracted_text, page_count }.
// Max 20 MB. Resolves the owning node via node_assets, downloads from the private
// node-pdfs bucket, extracts text, then writes nodes.extracted_text + content_hash
// (the content_hash change fires the S01 embed trigger). No quota.
//
// Best-effort: also writes ingest_documents + ingest_segments when those tables
// exist so page structure is not thrown away. Failures there never break the
// PDF path.

import { extractText, getDocumentProxy } from "npm:unpdf";
import { handlePreflight } from "../_shared/cors.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireString } from "../_shared/validate.ts";

const PDF_BUCKET = "node-pdfs";
const MAX_BYTES = 20 * 1024 * 1024; // 20 MB [D-EF-1]

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function writeIngestBestEffort(args: {
  userId: string;
  nodeId: string;
  assetId: string | null;
  storagePath: string;
  pageCount: number;
  extracted: string;
}): Promise<void> {
  try {
    const db = adminClient();
    const { data: doc, error: docErr } = await db
      .from("ingest_documents")
      .insert({
        user_id: args.userId,
        node_id: args.nodeId,
        asset_id: args.assetId,
        source_kind: "pdf",
        storage_path: args.storagePath,
        page_count: args.pageCount,
        status: "ready",
      })
      .select("id")
      .maybeSingle();
    if (docErr || !doc) {
      console.warn("extract-pdf-text: ingest_documents insert skipped:", docErr?.message);
      return;
    }

    // unpdf mergePages joins pages; store one segment so structure is retained
    // even without per-page splits today.
    const { error: segErr } = await db.from("ingest_segments").insert({
      document_id: (doc as { id: string }).id,
      segment_index: 0,
      page_number: null,
      content: args.extracted,
    });
    if (segErr) {
      console.warn("extract-pdf-text: ingest_segments insert skipped:", segErr.message);
    }
  } catch (e) {
    console.warn("extract-pdf-text: ingest write failed:", (e as Error).message);
  }
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    const body = await req.json().catch(() => ({}));
    let storagePath = requireString((body as { storage_path?: string }).storage_path, "storage_path");
    if (storagePath.startsWith(`${PDF_BUCKET}/`)) storagePath = storagePath.slice(PDF_BUCKET.length + 1);

    const db = adminClient();

    // Resolve the owning node + verify ownership (service role bypasses RLS).
    const { data: asset } = await db
      .from("node_assets")
      .select("id, node_id, nodes!inner(id, user_id, buckets!inner(user_id))")
      .eq("storage_path", storagePath)
      .maybeSingle();
    const node = (asset as {
      nodes?: { user_id?: string; buckets?: { user_id?: string } };
    } | null)?.nodes;
    const owner = node?.user_id ?? node?.buckets?.user_id;
    const nodeId = (asset as { node_id?: string } | null)?.node_id;
    const assetId = (asset as { id?: string } | null)?.id ?? null;
    if (!asset || !nodeId) throw new AppError("invalid_input", "asset not found");
    if (caller.userId && owner !== caller.userId) throw new AppError("unauthorized");

    // Download + enforce the 20 MB cap.
    const { data: blob, error: dlErr } = await db.storage.from(PDF_BUCKET).download(storagePath);
    if (dlErr || !blob) throw new AppError("invalid_input", "download failed");
    if (blob.size > MAX_BYTES) {
      throw new AppError("invalid_input", "PDF exceeds the 20 MB limit");
    }

    const bytes = new Uint8Array(await blob.arrayBuffer());
    const pdf = await getDocumentProxy(bytes);
    const { totalPages, text } = await extractText(pdf, { mergePages: true });
    const extracted = (Array.isArray(text) ? text.join("\n") : text).trim();

    const contentHash = await sha256Hex(extracted);
    const { error: updErr } = await db
      .from("nodes")
      .update({ extracted_text: extracted, content_hash: contentHash })
      .eq("id", nodeId);
    if (updErr) throw updErr;

    // Mark the asset ready when we have text; best-effort, never blocks the response.
    if (assetId) {
      await db
        .from("node_assets")
        .update({ extracted_text: extracted, parse_status: "ready" })
        .eq("id", assetId)
        .then(({ error }) => {
          if (error) console.warn("extract-pdf-text: asset update skipped:", error.message);
        });
    }

    if (owner) {
      await writeIngestBestEffort({
        userId: owner,
        nodeId,
        assetId,
        storagePath,
        pageCount: totalPages,
        extracted,
      });
    }

    return jsonResponse({ extracted_text: extracted, page_count: totalPages });
  } catch (err) {
    return toErrorResponse(err);
  }
});
