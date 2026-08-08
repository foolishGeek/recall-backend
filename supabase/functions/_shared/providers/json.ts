// Parsing model output. Previously duplicated between the generic router and
// the quiz path, which meant a fix to one silently left the other behind.

/**
 * Best-effort JSON parse of model output: strips code fences, then falls back
 * to the outermost {...} span. `salvage` handles a reply that was cut off
 * mid-array because the model ran out of output tokens — it recovers the
 * objects that did complete instead of throwing the whole batch away.
 */
export function parseJsonLoose(
  text: string,
  salvage?: (partial: string) => Record<string, unknown> | null,
): Record<string, unknown> | null {
  if (!text) return null;
  const cleaned = text.trim().replace(/^```(?:json)?/i, "").replace(/```$/i, "").trim();

  try {
    return JSON.parse(cleaned);
  } catch {
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(cleaned.slice(start, end + 1));
      } catch {
        return salvage ? salvage(cleaned.slice(start)) : null;
      }
    }
    return salvage ? salvage(cleaned) : null;
  }
}

/**
 * Pulls every complete top-level object out of a truncated JSON blob, keeping
 * only those that satisfy [accept]. String-aware so braces inside quoted text
 * do not confuse the depth count.
 */
export function salvageObjects(
  text: string,
  accept: (obj: Record<string, unknown>) => boolean,
): Record<string, unknown>[] {
  const objects: Record<string, unknown>[] = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escape = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (escape) escape = false;
      else if (ch === "\\") escape = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "{") {
      if (depth === 0) start = i;
      depth++;
      continue;
    }
    if (ch === "}") {
      depth--;
      if (depth === 0 && start >= 0) {
        try {
          const obj = JSON.parse(text.slice(start, i + 1));
          if (obj && typeof obj === "object" && accept(obj)) {
            objects.push(obj as Record<string, unknown>);
          }
        } catch {
          // Incomplete object; keep scanning for the next one.
        }
        start = -1;
      }
    }
  }
  return objects;
}
