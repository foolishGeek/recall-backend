// Standalone URL lines in note markdown (reference links / YouTube) must survive
// Aura evaluate rewrites. Mirrors recall-mobile/lib/core/utils/note_links.dart.

const URL_LINE = /^\s*(https?:\/\/\S+)\s*$/;

/** URLs that sit on their own line — reference links/videos, in document order. */
export function standaloneUrls(md: string | null | undefined): string[] {
  if (!md) return [];
  const out: string[] = [];
  for (const line of md.split("\n")) {
    const m = line.match(URL_LINE);
    if (m) out.push(m[1]);
  }
  return out;
}

/** Append any standalone URLs from [before] that are missing in [after]. */
export function mergeStandaloneUrls(
  before: string | null | undefined,
  after: string | null | undefined,
): string | null {
  if (after == null) return after ?? null;
  const original = standaloneUrls(before);
  if (original.length === 0) return after;

  const present = new Set(standaloneUrls(after).map(normalizeUrl));
  const missing = original.filter((u) => !present.has(normalizeUrl(u)));
  if (missing.length === 0) return after;

  const trimmed = after.replace(/\s+$/, "");
  const block = missing.join("\n");
  return trimmed.length === 0 ? block : `${trimmed}\n\n${block}`;
}

export interface LinkSuggestion {
  current_url: string;
  suggested_url: string;
  label: string;
}

function normalizeUrl(u: string): string {
  return u.trim().replace(/\/+$/, "").toLowerCase();
}

/** Match note URLs even when the model drops www / trailing slash / case. */
function urlsMatch(a: string, b: string): boolean {
  if (normalizeUrl(a) === normalizeUrl(b)) return true;
  try {
    const ua = new URL(a.trim());
    const ub = new URL(b.trim());
    const hostA = ua.hostname.replace(/^www\./, "").toLowerCase();
    const hostB = ub.hostname.replace(/^www\./, "").toLowerCase();
    const pathA = ua.pathname.replace(/\/+$/, "").toLowerCase() || "/";
    const pathB = ub.pathname.replace(/\/+$/, "").toLowerCase() || "/";
    return hostA === hostB && pathA === pathB;
  } catch {
    return false;
  }
}

function findNoteUrl(candidate: string, noteUrls: string[]): string | null {
  for (const u of noteUrls) {
    if (urlsMatch(candidate, u)) return u;
  }
  return null;
}

function isHttpUrl(u: string): boolean {
  try {
    const uri = new URL(u.trim());
    return (uri.protocol === "http:" || uri.protocol === "https:") &&
      uri.hostname.length > 0;
  } catch {
    return false;
  }
}

function shortLabel(url: string, provided?: string): string {
  const p = (provided ?? "").trim();
  if (p) return p.slice(0, 80);
  try {
    return new URL(url.trim()).hostname.replace(/^www\./, "");
  } catch {
    return url.trim().slice(0, 40);
  }
}

/**
 * Keep only suggestions that replace an existing note URL with a different
 * valid http(s) URL. Cap at [max] (default 2).
 * current_url is normalized back to the note's exact string for client matching.
 */
export function validateLinkSuggestions(
  raw: unknown,
  noteUrls: string[],
  max = 2,
): LinkSuggestion[] {
  if (!Array.isArray(raw) || noteUrls.length === 0 || max <= 0) return [];

  const seenCurrent = new Set<string>();
  const out: LinkSuggestion[] = [];

  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    const currentRaw = typeof row.current_url === "string" ? row.current_url.trim() : "";
    const suggested = typeof row.suggested_url === "string"
      ? row.suggested_url.trim()
      : "";
    if (!currentRaw || !suggested) continue;
    if (!isHttpUrl(currentRaw) || !isHttpUrl(suggested)) continue;

    const current = findNoteUrl(currentRaw, noteUrls);
    if (!current) continue;
    if (urlsMatch(current, suggested)) continue;

    const key = normalizeUrl(current);
    if (seenCurrent.has(key)) continue;
    seenCurrent.add(key);

    out.push({
      current_url: current,
      suggested_url: suggested,
      label: shortLabel(
        suggested,
        typeof row.label === "string" ? row.label : undefined,
      ),
    });
    if (out.length >= max) break;
  }
  return out;
}

const ANY_URL = /https?:\/\/[^\s)\]<>"']+/gi;

/** All http(s) URLs in the note (standalone lines, inline, legacy url column). */
export function collectNoteUrls(
  markdown: string | null | undefined,
  legacyUrl?: string | null,
): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const add = (raw: string) => {
    const u = raw.trim().replace(/[.,;:!?]+$/, "");
    const n = normalizeUrl(u);
    if (!n || seen.has(n)) return;
    if (!isHttpUrl(u)) return;
    seen.add(n);
    out.push(u);
  };
  for (const u of standaloneUrls(markdown)) add(u);
  if (markdown) {
    for (const m of markdown.matchAll(ANY_URL)) add(m[0]);
  }
  if (legacyUrl) add(legacyUrl);
  return out;
}
