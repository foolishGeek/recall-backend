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

function toHex(digest: ArrayBuffer): string {
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(text: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

async function sha256Buffer(data: ArrayBuffer): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", data));
}

const PARSER = "unpdf";
const PARSER_VERSION = "1";

/**
 * Record the parse lineage: which file, which parser, and the page structure.
 * Page boundaries are what later make precise citations, per-page retrieval and
 * structure-aware chunking possible, so they are kept even though the note only
 * stores the flattened text. Best-effort — never breaks the PDF path.
 */
async function writeIngestBestEffort(args: {
  userId: string;
  nodeId: string;
  assetId: string | null;
  storagePath: string;
  pages: { page: number; content: string }[];
  pageCount: number;
  bytes: number;
  sha256: string;
}): Promise<void> {
  try {
    const db = adminClient();
    const { data: doc, error: docErr } = await db
      .from("ingest_documents")
      .upsert({
        user_id: args.userId,
        node_id: args.nodeId,
        asset_id: args.assetId,
        source_kind: "pdf",
        source_id: args.assetId,
        storage_path: args.storagePath,
        mime_type: "application/pdf",
        bytes: args.bytes,
        sha256: args.sha256,
        parser: PARSER,
        parser_version: PARSER_VERSION,
        page_count: args.pageCount,
        status: "ready",
      }, { onConflict: "user_id,storage_path,sha256" })
      .select("id")
      .maybeSingle();
    if (docErr || !doc) {
      console.warn("extract-pdf-text: ingest_documents write skipped:", docErr?.message);
      return;
    }
    const documentId = (doc as { id: string }).id;

    // Offsets are into the same joined string that becomes nodes.extracted_text,
    // so a chunk can be traced back to a page.
    let cursor = 0;
    const segments = args.pages.map((p, i) => {
      const charStart = cursor;
      cursor += p.content.length + 1; // the "\n" used to join pages
      return {
        document_id: documentId,
        segment_index: i,
        page_number: p.page,
        content: p.content,
        char_start: charStart,
        char_end: charStart + p.content.length,
      };
    });

    if (segments.length === 0) return;

    await db.from("ingest_segments").delete().eq("document_id", documentId);
    const { error: segErr } = await db.from("ingest_segments").insert(segments);
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

    const buffer = await blob.arrayBuffer();
    const bytes = new Uint8Array(buffer);
    const pdf = await getDocumentProxy(bytes);
    // Per page, not merged: blank pages are dropped but the surviving pages keep
    // their real page numbers, and the joined text is exactly what the segment
    // character offsets refer to.
    const { totalPages, text } = await extractText(pdf, { mergePages: false });
    const rawPages = Array.isArray(text) ? text.map((t) => String(t ?? "")) : [String(text ?? "")];
    const pages = rawPages
      .map((content, i) => ({ page: i + 1, content: content.trim() }))
      .filter((p) => p.content.length > 0);
    const extracted = pages.map((p) => p.content).join("\n");

    const contentHash = await sha256Hex(extracted);
    const fileSha = await sha256Buffer(buffer);
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
        pages,
        pageCount: totalPages,
        bytes: buffer.byteLength,
        sha256: fileSha,
      });
    }

    return jsonResponse({ extracted_text: extracted, page_count: totalPages });
  } catch (err) {
    return toErrorResponse(err);
  }
});
