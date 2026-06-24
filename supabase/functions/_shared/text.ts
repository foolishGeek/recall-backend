// Small text utilities shared by AI features. Inputs are always sanitized +
// truncated before any provider call [AI-PROMPTS.md § Safety].

/** Removes HTML tags and collapses whitespace. */
export function stripHtml(input: string | null | undefined): string {
  if (!input) return "";
  return input
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Hard-caps a string to `maxChars` characters. */
export function truncate(input: string, maxChars: number): string {
  if (input.length <= maxChars) return input;
  return input.slice(0, maxChars);
}

/** Rough token estimate (~4 chars/token) for usage when a provider omits it. */
export function estimateTokens(input: string): number {
  return Math.ceil((input?.length ?? 0) / 4);
}
