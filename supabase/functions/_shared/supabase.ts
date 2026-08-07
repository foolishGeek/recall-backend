// Service-role Supabase client for Edge Functions. The service-role key bypasses
// RLS, so all owner/tier checks must be done explicitly in SQL (gate RPCs) or
// by filtering on the resolved user id. Never expose this client to callers.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export type { SupabaseClient };

let cached: SupabaseClient | null = null;

export function adminClient(): SupabaseClient {
  if (cached) return cached;
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set");
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}

// supabase-js infers an embedded relation as an array, so `buckets!inner(name)`
// is typed `{ name: any }[]` even though a to-one relation returns exactly one
// object. Every call site that annotates the real shape therefore needs a
// double cast; these say why once instead of repeating it.

export function rowsAs<T>(data: unknown): T[] {
  return (data ?? []) as T[];
}

export function rowAs<T>(data: unknown): T | null {
  return (data ?? null) as T | null;
}
