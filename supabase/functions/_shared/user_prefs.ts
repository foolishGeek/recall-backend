// Per-user personalization [D-AI-8]. Loads the user's learned style directives
// and renders a short, sanitized "USER PREFERENCES" block that features append
// to their system prompt. Length-capped and ignored when empty. Never throws.

import { adminClient } from "./supabase.ts";

const MAX_BLOCK_CHARS = 600;

const DIRECTIVE_LINES: Record<string, Record<string, string>> = {
  length: {
    concise: "Keep answers concise.",
    detailed: "Give thorough, detailed answers.",
  },
  depth: { deep: "Go a level deeper into the reasoning." },
  tone: { plain: "Use very plain, simple language." },
  format: { steps: "Prefer a clear step-by-step structure." },
};

/** Returns a prompt suffix like "\n\nUSER PREFERENCES...\n- ..." or "". */
export async function userDirectives(userId: string): Promise<string> {
  try {
    const { data, error } = await adminClient()
      .from("ai_user_preferences")
      .select("style_directives, custom_notes")
      .eq("user_id", userId)
      .maybeSingle();
    if (error || !data) return "";

    const directives = (data as { style_directives?: Record<string, unknown> }).style_directives ?? {};
    const notes = (data as { custom_notes?: string[] }).custom_notes ?? [];

    const lines: string[] = [];
    for (const [key, val] of Object.entries(directives)) {
      if (key === "examples" && val === true) {
        lines.push("Include concrete examples.");
        continue;
      }
      const line = DIRECTIVE_LINES[key]?.[String(val)];
      if (line) lines.push(line);
    }
    // A couple of the most recent raw notes for nuance the mapping missed.
    for (const note of notes.slice(-2)) {
      const t = (note ?? "").trim();
      if (t) lines.push(t);
    }
    if (lines.length === 0) return "";

    const block = `\n\nUSER PREFERENCES (honor these when reasonable; they never override accuracy):\n- ${
      lines.join("\n- ")
    }`;
    return block.slice(0, MAX_BLOCK_CHARS);
  } catch (_e) {
    return "";
  }
}
