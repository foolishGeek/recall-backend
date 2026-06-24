// link-preview [D-EF-2]. POST { url } → the canonical 7-field preview. YouTube
// fills duration_sec + video_id. SSRF-safe: blocks private IPs, ≤3 redirects,
// 5s timeout. Any failure returns a minimal { title: url, ... } (never errors).

import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse, errorResponse } from "../_shared/errors.ts";
import { isHostPublic } from "../_shared/ssrf.ts";

interface Preview {
  title: string | null;
  description: string | null;
  image_url: string | null;
  canonical_url: string | null;
  site_name: string | null;
  duration_sec: number | null;
  video_id: string | null;
}

const TIMEOUT_MS = 5000;
const MAX_REDIRECTS = 3;

function minimal(url: string): Preview {
  return {
    title: url,
    description: null,
    image_url: null,
    canonical_url: null,
    site_name: null,
    duration_sec: null,
    video_id: null,
  };
}

function youtubeVideoId(u: URL): string | null {
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  if (host === "youtu.be") return u.pathname.slice(1).split("/")[0] || null;
  if (host.endsWith("youtube.com")) {
    if (u.pathname === "/watch") return u.searchParams.get("v");
    const m = u.pathname.match(/^\/(?:embed|shorts|v)\/([^/?#]+)/);
    if (m) return m[1];
  }
  return null;
}

function metaTag(html: string, names: string[]): string | null {
  for (const name of names) {
    const re = new RegExp(
      `<meta[^>]+(?:property|name)=["']${name}["'][^>]+content=["']([^"']*)["']`,
      "i",
    );
    const m = html.match(re);
    if (m) return decodeEntities(m[1]);
    const re2 = new RegExp(
      `<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']${name}["']`,
      "i",
    );
    const m2 = html.match(re2);
    if (m2) return decodeEntities(m2[1]);
  }
  return null;
}

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

// Manual redirect follow with per-hop SSRF re-validation.
async function safeFetch(startUrl: string, signal: AbortSignal): Promise<Response | null> {
  let current = startUrl;
  for (let i = 0; i <= MAX_REDIRECTS; i++) {
    let u: URL;
    try {
      u = new URL(current);
    } catch {
      return null;
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    if (!(await isHostPublic(u.hostname))) return null;

    const res = await fetch(current, {
      redirect: "manual",
      signal,
      headers: { "User-Agent": "RecallLinkPreview/1.0", Accept: "text/html,*/*" },
    });

    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel();
      if (!loc) return null;
      current = new URL(loc, current).toString();
      continue;
    }
    return res;
  }
  return null; // too many redirects
}

async function buildPreview(rawUrl: string): Promise<Preview> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await safeFetch(rawUrl, controller.signal);
    if (!res || !res.ok) return minimal(rawUrl);

    const ct = res.headers.get("content-type") ?? "";
    if (!ct.includes("text/html")) {
      await res.body?.cancel();
      return minimal(rawUrl);
    }

    const html = (await res.text()).slice(0, 500_000);
    const finalUrl = new URL(res.url || rawUrl);

    const titleTag = html.match(/<title[^>]*>([^<]*)<\/title>/i);
    const canonical = html.match(/<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']*)["']/i);

    const preview: Preview = {
      title: metaTag(html, ["og:title", "twitter:title"]) ??
        (titleTag ? decodeEntities(titleTag[1].trim()) : rawUrl),
      description: metaTag(html, ["og:description", "description", "twitter:description"]),
      image_url: metaTag(html, ["og:image", "twitter:image"]),
      canonical_url: canonical ? decodeEntities(canonical[1]) : finalUrl.toString(),
      site_name: metaTag(html, ["og:site_name"]),
      duration_sec: null,
      video_id: null,
    };

    const vid = youtubeVideoId(finalUrl);
    if (vid) {
      preview.video_id = vid;
      const len = html.match(/"lengthSeconds":"(\d+)"/);
      if (len) preview.duration_sec = Number(len[1]);
    }

    return preview;
  } catch {
    return minimal(rawUrl);
  } finally {
    clearTimeout(timer);
  }
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") return errorResponse("invalid_input", "POST only");

  let url: string;
  try {
    const body = await req.json();
    url = body.url;
    new URL(url); // validate
  } catch {
    return errorResponse("invalid_input", "valid url required");
  }

  const preview = await buildPreview(url);
  return jsonResponse(preview);
});
