// Loads app_config once per invocation and exposes typed getters. Keys mirror
// Roadmap/sprints/AI-PROMPTS.md "Global constants" + CANON [D-SCHEMA-9].

import { adminClient } from "./supabase.ts";

export class AppConfig {
  private map: Record<string, unknown>;
  private constructor(map: Record<string, unknown>) {
    this.map = map;
  }

  static async load(): Promise<AppConfig> {
    const { data, error } = await adminClient().from("app_config").select("key, value");
    if (error) throw error;
    const map: Record<string, unknown> = {};
    for (const row of data ?? []) map[row.key as string] = row.value;
    return new AppConfig(map);
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
