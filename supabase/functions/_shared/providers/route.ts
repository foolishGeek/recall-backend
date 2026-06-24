// Model routing [AI-PROMPTS.md § Model routing, D-AI-1]:
//   free    → Gemini Flash
//   premium → Claude Sonnet
//   fallback (on provider failure) → GPT-4o-mini
// Generation is JSON-only with one "valid JSON only" retry, then provider_error.
// Model ids are read from app_config (overridable) with canon defaults.

import { AppConfig } from "../config.ts";
import { AppError } from "../errors.ts";
import { GenerationResult, Usage } from "./types.ts";
import { geminiGenerateJson } from "./gemini.ts";
import { anthropicGenerateJson } from "./anthropic.ts";
import { openaiGenerateJson } from "./openai.ts";

export type Tier = "free" | "premium";

export interface RoutedResult {
  json: Record<string, unknown>;
  model: string;
  usage: Usage;
}

function premiumModelId(label: string): string {
  // app_config stores the display label "claude-sonnet"; map it to an API id.
  if (label.startsWith("claude-") && label.includes("-2")) return label; // already a full id
  return "claude-3-5-sonnet-latest";
}

function parseJsonLoose(text: string): Record<string, unknown> | null {
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
        return null;
      }
    }
    return null;
  }
}

type Generate = (a: { system: string; user: string; apiKey: string; model: string }) => Promise<GenerationResult>;

async function attempt(
  gen: Generate,
  system: string,
  user: string,
  apiKey: string,
  model: string,
): Promise<{ json: Record<string, unknown>; usage: Usage }> {
  const first = await gen({ system, user, apiKey, model });
  const parsed = parseJsonLoose(first.text);
  if (parsed) return { json: parsed, usage: first.usage };

  // Retry once with an explicit JSON reminder [§6 edge cases].
  const second = await gen({
    system,
    user: `${user}\n\nIMPORTANT: Output valid JSON only.`,
    apiKey,
    model,
  });
  const reparsed = parseJsonLoose(second.text);
  if (reparsed) {
    return {
      json: reparsed,
      usage: {
        input_tokens: first.usage.input_tokens + second.usage.input_tokens,
        output_tokens: first.usage.output_tokens + second.usage.output_tokens,
      },
    };
  }
  throw new AppError("provider_error", "Model did not return valid JSON.");
}

export async function generateJson(
  config: AppConfig,
  tier: Tier,
  system: string,
  user: string,
): Promise<RoutedResult> {
  const fallbackModel = config.str("ai_model_fallback", "gpt-4o-mini");
  const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";

  let primaryGen: Generate;
  let primaryKey: string;
  let primaryModel: string;

  if (tier === "premium") {
    primaryGen = anthropicGenerateJson;
    primaryKey = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
    primaryModel = premiumModelId(config.str("ai_model_premium", "claude-sonnet"));
  } else {
    primaryGen = geminiGenerateJson;
    primaryKey = Deno.env.get("GEMINI_API_KEY") ?? "";
    primaryModel = config.str("ai_model_free", "gemini-1.5-flash");
  }

  try {
    if (!primaryKey) throw new AppError("provider_error", "Primary provider key missing.");
    const out = await attempt(primaryGen, system, user, primaryKey, primaryModel);
    return { json: out.json, model: primaryModel, usage: out.usage };
  } catch (err) {
    // Fall back to GPT-4o-mini once on any primary failure.
    if (!openaiKey) throw err instanceof AppError ? err : new AppError("provider_error");
    const out = await attempt(openaiGenerateJson, system, user, openaiKey, fallbackModel);
    return { json: out.json, model: fallbackModel, usage: out.usage };
  }
}
