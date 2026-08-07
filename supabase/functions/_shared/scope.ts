// What content an AI request is allowed to look at.
//
// Today every scope bottoms out in "buckets the user has active", but the app
// is heading towards notes that belong to no bucket, single-note chats, and
// attachments searched in their own space. So features ask for a [ResolvedScope]
// instead of juggling bucket id arrays: when those sources land, this resolver
// and match_chunks change, and the feature handlers do not.
//
// It also removes a real inconsistency — rag_chat treated `bucket_ids: []` as
// "no scope" while quiz_generate treated it as "all active buckets".
//
// Accepts both the legacy { bucketIds, nodeIds } shape and the new
// { scope: { kind, ids } } descriptor via shimScopeRequest.

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
  /** Bucket ids to search. Always a subset of the user's active buckets. */
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
 * Intersects the caller's request with the buckets the user actually has
 * active, so a client can never widen its own scope by sending extra ids.
 */
export async function resolveScope(
  db: SupabaseClient,
  userId: string,
  request: ScopeRequest = {},
): Promise<ResolvedScope> {
  const { data, error } = await db.rpc("active_buckets_for_user", { uid: userId });
  if (error) throw error;

  const activeIds: string[] = (data ?? []).map((b: { id: string }) => b.id);
  const requested = request.bucketIds;
  const nodeIds = request.nodeIds?.length ? request.nodeIds : null;
  const assetIds = request.assetIds?.length ? request.assetIds : null;

  // An explicit empty array is a real answer ("nothing selected"), so it is
  // honoured rather than silently widened to every active bucket.
  const bucketIds = requested == null
    ? activeIds
    : activeIds.filter((id) => requested.includes(id));

  let kind: ScopeKind = request.scope?.kind ?? "active_buckets";
  if (!request.scope) {
    if (assetIds) kind = "assets";
    else if (nodeIds) kind = "nodes";
    else if (requested != null) kind = "buckets";
  }

  const isEmpty = kind === "assets"
    ? !assetIds?.length
    : kind === "nodes"
    ? !nodeIds?.length
    : bucketIds.length === 0;

  return { kind, bucketIds, nodeIds, assetIds, isEmpty };
}
