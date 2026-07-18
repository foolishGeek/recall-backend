// Searchable text for a node row. The embed pipeline only chunks `extracted_text`,
// but link/YouTube nodes often store metadata in `link_preview_json` without
// populating `extracted_text` yet — RAG + evaluate fall back to this assembly.

import { stripHtml } from "./text.ts";
import { standaloneUrls } from "./note_links.ts";

export interface NodeRow {
  id: string;
  title?: string;
  extracted_text?: string | null;
  markdown?: string | null;
  url?: string | null;
  link_preview_json?: Record<string, unknown> | null;
  bucket_id?: string;
}

/**
 * Best-effort corpus for a node: extracted_text first, then markdown / preview / url.
 * When extracted_text wins, still append standalone URL lines from markdown (and
 * legacy url) so evaluate/RAG never hide reference links the user attached.
 */
export function nodeCorpusText(node: NodeRow): string {
  const fromExtracted = stripHtml(node.extracted_text);
  if (fromExtracted) {
    return appendAssetUrls(fromExtracted, node);
  }

  const parts: string[] = [];
  const title = (node.title ?? "").trim();
  if (title) parts.push(title);

  const md = stripHtml(node.markdown);
  if (md) parts.push(md);

  const lp = node.link_preview_json ?? {};
  const lpTitle = typeof lp.title === "string" ? lp.title.trim() : "";
  if (lpTitle && lpTitle !== title) parts.push(lpTitle);
  if (typeof lp.description === "string" && lp.description.trim()) {
    parts.push(lp.description.trim());
  }
  if (typeof lp.site_name === "string" && lp.site_name.trim()) {
    parts.push(lp.site_name.trim());
  }

  const url = (node.url ?? "").trim();
  if (url) parts.push(url);

  return parts.join("\n").trim();
}

function appendAssetUrls(base: string, node: NodeRow): string {
  const present = new Set(
    base.toLowerCase().match(/https?:\/\/\S+/g)?.map((u) =>
      u.replace(/\/+$/, "")
    ) ?? [],
  );
  const extra: string[] = [];
  for (const u of standaloneUrls(node.markdown)) {
    const key = u.trim().replace(/\/+$/, "").toLowerCase();
    if (!present.has(key)) {
      present.add(key);
      extra.push(u.trim());
    }
  }
  const legacy = (node.url ?? "").trim();
  if (legacy) {
    const key = legacy.replace(/\/+$/, "").toLowerCase();
    if (!present.has(key)) extra.push(legacy);
  }
  if (extra.length === 0) return base;
  return `${base}\n\n${extra.join("\n")}`;
}
