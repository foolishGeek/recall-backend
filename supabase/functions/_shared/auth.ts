// Resolve the caller from the Authorization bearer token. The gateway verifies
// the JWT signature (verify_jwt = true) before we run, so decoding the payload
// for `sub` / `role` is safe here. Service-role calls (the embed DB trigger)
// carry role = "service_role" and have no user subject.

import { AppError } from "./errors.ts";

export interface Caller {
  userId: string | null;
  isServiceRole: boolean;
}

function decodeJwtPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length < 2) throw new AppError("unauthorized");
  const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  try {
    return JSON.parse(atob(padded));
  } catch {
    throw new AppError("unauthorized");
  }
}

export function resolveCaller(req: Request): Caller {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header || !header.toLowerCase().startsWith("bearer ")) {
    throw new AppError("unauthorized");
  }
  const token = header.slice(7).trim();
  const payload = decodeJwtPayload(token);
  const role = (payload["role"] as string | undefined) ?? null;
  if (role === "service_role") {
    return { userId: null, isServiceRole: true };
  }
  const sub = (payload["sub"] as string | undefined) ?? null;
  if (!sub) throw new AppError("unauthorized");
  return { userId: sub, isServiceRole: false };
}
