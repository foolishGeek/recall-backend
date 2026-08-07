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

import { SupabaseClient } from "./supabase.ts";

export type ScopeKind =
  | "active_buckets" // default: everything currently in rotation
  | "buckets" // an explicit subset of the user's buckets
  | "nodes"; // specific notes, regardless of bucket

export interface ScopeRequest {
  /** Explicit bucket subset. Empty array means "no buckets", not "all". */
  bucketIds?: string[] | null;
  /** Narrows to specific notes within the resolved buckets. */
  nodeIds?: string[] | null;
}

export interface ResolvedScope {
  kind: ScopeKind;
  /** Bucket ids to search. Always a subset of the user's active buckets. */
  bucketIds: string[];
  /** Node filter for match_chunks, or null for "any node in scope". */
  nodeIds: string[] | null;
  /** True when there is nothing to search and retrieval should be skipped. */
  isEmpty: boolean;
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

  // An explicit empty array is a real answer ("nothing selected"), so it is
  // honoured rather than silently widened to every active bucket.
  const bucketIds = requested == null
    ? activeIds
    : activeIds.filter((id) => requested.includes(id));

  let kind: ScopeKind = "active_buckets";
  if (nodeIds) kind = "nodes";
  else if (requested != null) kind = "buckets";

  return { kind, bucketIds, nodeIds, isEmpty: bucketIds.length === 0 };
}
