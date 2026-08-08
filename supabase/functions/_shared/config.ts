// Typed access to app_config. Keys mirror Roadmap/sprints/AI-PROMPTS.md
// "Global constants" + CANON [D-SCHEMA-9].
//
// Cached for [TTL_MS] per warm isolate: this table is read on every AI request
// but changes only when someone edits it, so a fresh SELECT each time is a
// round trip on the critical path for nothing. The TTL is what bounds how long
// a config change takes to reach traffic — keep it short.

import { adminClient } from "./supabase.ts";

const TTL_MS = 60_000;

let cache: { config: AppConfig; loadedAt: number } | null = null;
let inFlight: Promise<AppConfig> | null = null;

export class AppConfig {
  private map: Record<string, unknown>;
  private constructor(map: Record<string, unknown>) {
    this.map = map;
  }

  static async load(): Promise<AppConfig> {
    if (cache && Date.now() - cache.loadedAt < TTL_MS) return cache.config;
    // Concurrent requests in a warm isolate share one refresh.
    if (inFlight) return inFlight;

    inFlight = (async () => {
      const { data, error } = await adminClient().from("app_config").select("key, value");
      if (error) {
        // A blip should not take AI down when we already have a usable copy.
        if (cache) return cache.config;
        throw error;
      }
      const map: Record<string, unknown> = {};
      for (const row of data ?? []) map[row.key as string] = row.value;
      const config = new AppConfig(map);
      cache = { config, loadedAt: Date.now() };
      return config;
    })();

    try {
      return await inFlight;
    } finally {
      inFlight = null;
    }
  }

  int(key: string, fallback: number): number {
    const v = this.map[key];
    const n = typeof v === "string" ? Number(v) : (v as number);
    return Number.isFinite(n) ? Math.trunc(n) : fallback;
  }

  num(key: string, fallback: number): number {
    const v = this.map[key];
    const n = typeof v === "string" ? Number(v) : (v as number);
    return Number.isFinite(n) ? n : fallback;
  }

  bool(key: string, fallback: boolean): boolean {
    const v = this.map[key];
    if (typeof v === "boolean") return v;
    if (typeof v === "string") return v === "true";
    return fallback;
  }

  str(key: string, fallback: string): string {
    const v = this.map[key];
    return typeof v === "string" && v.length > 0 ? v : fallback;
  }
}
