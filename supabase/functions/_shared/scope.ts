// What content an AI request is allowed to look at.
//
// Features ask for a [ResolvedScope] instead of juggling bucket id arrays:
// when notes without a bucket, single-note chats, or attachment spaces land,
// this resolver and match_chunks change — the feature handlers do not.
//
// Explicit bucket ids mean "these buckets I own", not "these among my active
// stack". Asking Aura from a cooling bucket must still read that bucket's notes.
// The default (no ids) stays the active set, which is what a global Ask Aura
// without a scope means.

import { SupabaseClient } from "./supabase.ts";

export type ScopeKind =
  | "active_buckets" // default: everything currently in rotation
  | "buckets" // an explicit subset of the user's buckets
  | "nodes" // specific notes, regardless of bucket
  | "assets"; // specific attachments

export interface ScopeDescriptor {
  kind: ScopeKind;
  ids: string[];
}

export interface ScopeRequest {
  /** Explicit bucket subset. Empty array means "no buckets", not "all". */
  bucketIds?: string[] | null;
  /** Narrows to specific notes within the resolved buckets. */
  nodeIds?: string[] | null;
  /** New descriptor shape; preferred when present. */
  scope?: ScopeDescriptor | null;
  /** Narrows to specific assets (source_kind = asset). */
  assetIds?: string[] | null;
}

export interface ResolvedScope {
  kind: ScopeKind;
  /** Bucket ids to search. Owned by the user; may be empty. */
  bucketIds: string[];
  /** Node filter for match_chunks, or null for "any node in scope". */
  nodeIds: string[] | null;
  /** Asset filter for match_chunks_hybrid_v2, or null. */
  assetIds: string[] | null;
  /** True when there is nothing to search and retrieval should be skipped. */
  isEmpty: boolean;
}

/**
 * Normalises either the legacy { bucketIds, nodeIds } / snake_case payload or
 * the new { scope: { kind, ids } } descriptor. Old payloads keep working.
 */
export function shimScopeRequest(raw: Record<string, unknown> | ScopeRequest): ScopeRequest {
  if (raw && typeof raw === "object" && "bucketIds" in raw && !("bucket_ids" in raw) && !("scope" in raw)) {
    return raw as ScopeRequest;
  }

  const body = raw as Record<string, unknown>;
  const descriptor = body.scope;
  if (
    descriptor &&
    typeof descriptor === "object" &&
    !Array.isArray(descriptor) &&
    typeof (descriptor as ScopeDescriptor).kind === "string" &&
    Array.isArray((descriptor as ScopeDescriptor).ids)
  ) {
    const d = descriptor as ScopeDescriptor;
    switch (d.kind) {
      case "buckets":
        return { scope: d, bucketIds: d.ids, nodeIds: null, assetIds: null };
      case "nodes":
        return { scope: d, bucketIds: null, nodeIds: d.ids, assetIds: null };
      case "assets":
        return { scope: d, bucketIds: null, nodeIds: null, assetIds: d.ids };
      case "active_buckets":
      default:
        return { scope: d, bucketIds: null, nodeIds: null, assetIds: null };
    }
  }

  const bucketIds = Array.isArray(body.bucket_ids)
    ? (body.bucket_ids as string[])
    : Array.isArray(body.bucketIds)
    ? (body.bucketIds as string[])
    : null;
  const nodeIds = Array.isArray(body.node_ids)
    ? (body.node_ids as string[])
    : Array.isArray(body.nodeIds)
    ? (body.nodeIds as string[])
    : null;
  const assetIds = Array.isArray(body.asset_ids)
    ? (body.asset_ids as string[])
    : Array.isArray(body.assetIds)
    ? (body.assetIds as string[])
    : null;

  return { bucketIds, nodeIds, assetIds };
}

/**
 * Resolves the caller's request into a search scope.
 *
 * - No bucket ids → active stack (the default Ask Aura surface).
 * - Explicit bucket ids → those buckets the user owns, even if cooling.
 * - Empty array → empty scope (honoured, never widened).
 * - Node / asset ids are ownership-checked separately so a client cannot
 *   widen into someone else's notes by guessing uuids.
 */
export async function resolveScope(
  db: SupabaseClient,
  userId: string,
  request: ScopeRequest = {},
): Promise<ResolvedScope> {
  const requested = request.bucketIds;
  const nodeIds = request.nodeIds?.length ? request.nodeIds : null;
  const assetIds = request.assetIds?.length ? request.assetIds : null;

  let kind: ScopeKind = request.scope?.kind ?? "active_buckets";
  if (!request.scope) {
    if (assetIds) kind = "assets";
    else if (nodeIds) kind = "nodes";
    else if (requested != null) kind = "buckets";
  }

  let bucketIds: string[] = [];
  if (kind === "assets" || kind === "nodes") {
    bucketIds = [];
  } else if (requested == null) {
    const { data, error } = await db.rpc("active_buckets_for_user", { uid: userId });
    if (error) throw error;
    bucketIds = (data ?? []).map((b: { id: string }) => b.id);
  } else if (requested.length === 0) {
    bucketIds = [];
  } else {
    // Owned buckets only — not "owned and currently active". Asking from a
    // cooling bucket must still confine to that bucket's notes, not silently
    // empty or widen to the active set.
    const { data, error } = await db
      .from("buckets")
      .select("id")
      .eq("user_id", userId)
      .is("deleted_at", null)
      .in("id", requested);
    if (error) throw error;
    bucketIds = (data ?? []).map((b: { id: string }) => b.id);
  }

  // Node scope: drop ids the user does not own. Without this, service-role
  // retrieval would happily read another account's note into the prompt.
  let ownedNodes = nodeIds;
  if (nodeIds) {
    const { data, error } = await db
      .from("nodes")
      .select("id")
      .eq("user_id", userId)
      .is("deleted_at", null)
      .in("id", nodeIds);
    if (error) throw error;
    ownedNodes = (data ?? []).map((n: { id: string }) => n.id);
  }

  // Asset scope: same ownership check via the parent note.
  let ownedAssets = assetIds;
  if (assetIds) {
    const { data, error } = await db
      .from("node_assets")
      .select("id, nodes!inner(user_id)")
      .in("id", assetIds)
      .eq("nodes.user_id", userId);
    if (error) throw error;
    ownedAssets = (data ?? []).map((a: { id: string }) => a.id);
  }

  const isEmpty = kind === "assets"
    ? !ownedAssets?.length
    : kind === "nodes"
    ? !ownedNodes?.length
    : bucketIds.length === 0;

  return {
    kind,
    bucketIds,
    nodeIds: ownedNodes,
    assetIds: ownedAssets,
    isEmpty,
  };
}
