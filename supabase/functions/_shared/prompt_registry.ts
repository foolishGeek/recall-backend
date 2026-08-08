// Prompts stay TypeScript constants — git is already good version control.
// What the database needs is a stable id to point interactions at, so each
// prompt body registers itself by content hash the first time it is used.
//
// Memoised per isolate, so this costs one insert per prompt per cold start and
// nothing after that. A failure just leaves prompt_id null; the sha is still
// recorded on the interaction, so nothing is lost.

import { adminClient } from "./supabase.ts";

export interface PromptRef {
  promptId: string | null;
  sha: string;
}

const memo = new Map<string, PromptRef>();

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function registerPrompt(feature: string, body: string): Promise<PromptRef> {
  const sha = await sha256Hex(body);
  const cached = memo.get(sha);
  if (cached) return cached;

  let promptId: string | null = null;
  try {
    const { data, error } = await adminClient().rpc("ai_register_prompt", {
      p_feature: feature,
      p_body: body,
      p_content_sha: sha,
    });
    if (error) console.error("ai_register_prompt failed:", error.message);
    else promptId = (data as string) ?? null;
  } catch (e) {
    console.error("ai_register_prompt threw:", (e as Error).message);
  }

  const ref: PromptRef = { promptId, sha };
  // Cache even on failure so a broken registry cannot add a round-trip per call.
  memo.set(sha, ref);
  return ref;
}
