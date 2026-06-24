// Tiny input validators shared across Edge Functions.

import { AppError } from "./errors.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

export function requireUuid(v: unknown, field: string): string {
  if (!isUuid(v)) throw new AppError("invalid_input", `${field} must be a uuid`);
  return v;
}

export function requireString(v: unknown, field: string): string {
  if (typeof v !== "string" || v.trim().length === 0) {
    throw new AppError("invalid_input", `${field} is required`);
  }
  return v;
}

export function asUuidArray(v: unknown): string[] | null {
  if (v == null) return null;
  if (!Array.isArray(v)) return null;
  const out = v.filter(isUuid);
  return out.length ? out : null;
}
