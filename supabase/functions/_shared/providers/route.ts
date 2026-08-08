// Model routing [AI-PROMPTS.md § Model routing, D-AI-1]:
//   free    → Gemini Flash
//   premium → Claude Sonnet
//   fallback (on a retryable provider failure) → GPT-4o-mini
//
// Generation is JSON-only with one "valid JSON only" retry, then provider_error.
// Model ids are read from app_config (overridable) with canon defaults; sampling
// comes from ai_feature_policy via the caller's reservation.

import { AppConfig } from "../config.ts";
import { AppError } from "../errors.ts";
import { DEFAULT_TIMEOUT_MS } from "./http.ts";
import { parseJsonLoose } from "./json.ts";
import {
  GenerateArgs,
  GenerateStream,
  GenerationResult,
  ProviderError,
  Sampling,
  Usage,
} from "./types.ts";
import { geminiGenerateJson, geminiStreamText } from "./gemini.ts";
import { anthropicGenerateJson, anthropicStreamText } from "./anthropic.ts";
import { openaiGenerateJson, openaiStreamText } from "./openai.ts";
import { selfhostConfigured, selfhostGenerateJson, selfhostStreamText } from "./selfhost.ts";

export type Tier = "free" | "premium";

export interface RoutedResult {
  json: Record<string, unknown>;
  model: string;
  provider: string;
  usage: Usage;
}

export type Generate = (a: GenerateArgs) => Promise<GenerationResult>;

/** One provider the router may try, in order. */
export interface Candidate {
  provider: string;
  generate: Generate;
  /** Set once a provider gains SSE support; absent means buffered only. */
  stream?: GenerateStream;
  apiKey: string;
  model: string;
}

/** True when the whole ladder can stream, so chat can promise tokens. */
export function canStream(candidates: Candidate[]): boolean {
  const usable = candidates.filter((c) => c.apiKey);
  return usable.length > 0 && usable.every((c) => c.stream);
}

function premiumModelId(label: string): string {
  // app_config stores the display label "claude-sonnet"; map to a current API id.
  if (label.startsWith("claude-") && label.includes("-2")) return label;
  if (label.startsWith("claude-sonnet-4")) return label;
  return "claude-sonnet-4-20250514";
}

export function sumUsage(a: Usage, b: Usage): Usage {
  return {
    input_tokens: a.input_tokens + b.input_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
  };
}

export interface AttemptOptions extends Sampling {
  signal?: AbortSignal;
  timeoutMs?: number;
  /** Recovers usable data from a reply truncated mid-array. */
  salvage?: (partial: string) => Record<string, unknown> | null;
  /** Rejects a parsed-but-useless reply so the JSON retry still fires. */
  accept?: (json: Record<string, unknown>) => boolean;
}

/**
 * One provider, up to two calls: the request, then a single retry that spells
 * out the JSON requirement. Beyond that the provider is not going to comply and
 * a third call is just spend.
 */
export async function attempt(
  candidate: Candidate,
  system: string,
  user: string,
  opts: AttemptOptions = {},
): Promise<{ json: Record<string, unknown>; usage: Usage }> {
  const accept = opts.accept ?? (() => true);
  const call = (u: string) =>
    candidate.generate({
      system,
      user: u,
      apiKey: candidate.apiKey,
      model: candidate.model,
      temperature: opts.temperature,
      maxTokens: opts.maxTokens,
      signal: opts.signal,
      timeoutMs: opts.timeoutMs,
    });

  const first = await call(user);
  const parsed = parseJsonLoose(first.text, opts.salvage);
  if (parsed && accept(parsed)) return { json: parsed, usage: first.usage };

  const second = await call(`${user}\n\nIMPORTANT: Output valid JSON only.`);
  const reparsed = parseJsonLoose(second.text, opts.salvage);
  const usage = sumUsage(first.usage, second.usage);
  if (reparsed && accept(reparsed)) return { json: reparsed, usage };

  throw new ProviderError(candidate.provider, null, true, "Model did not return valid JSON.");
}

/**
 * Walks the candidates in order, moving on only when a failure is worth
 * retrying elsewhere. A prompt the model refuses on size or shape fails the
 * same way everywhere, so that stops the ladder immediately instead of spending
 * a second provider's tokens to reach the same rejection.
 */
export async function runLadder(
  candidates: Candidate[],
  system: string,
  user: string,
  opts: AttemptOptions = {},
): Promise<RoutedResult> {
  const usable = candidates.filter((c) => c.apiKey);
  if (usable.length === 0) {
    throw new AppError("provider_error", "No AI provider is configured.");
  }

  let last: unknown;
  for (const candidate of usable) {
    try {
      const out = await attempt(candidate, system, user, opts);
      return {
        json: out.json,
        model: candidate.model,
        provider: candidate.provider,
        usage: out.usage,
      };
    } catch (err) {
      last = err;
      const retryable = err instanceof ProviderError ? err.retryable : false;
      if (!retryable) break;
      console.error(`provider ${candidate.provider} failed, trying next:`, (err as Error).message);
    }
  }

  throw new AppError(
    "provider_error",
    last instanceof Error ? last.message : "All AI providers failed.",
  );
}

/** What a completed stream reports back, for the ledger and the capture spine. */
export interface StreamOutcome {
  model: string;
  provider: string;
  usage: Usage;
  /** True when the reader already saw tokens and the stream then stopped. */
  truncated?: boolean;
}

/**
 * Walks the ladder yielding text deltas, and reports which provider produced
 * them once it is done.
 *
 * The fail-over rule is stricter than the buffered one: a provider can only be
 * replaced while nothing has been sent to the reader yet. Once the user has seen
 * a sentence, switching providers would append a second, unrelated answer to a
 * half-finished one — worse than an honest error, so from the first delta a
 * failure ends the stream. If tokens were already emitted, we still return the
 * provider that wrote them so the ledger is not left blank.
 */
export async function* streamLadder(
  candidates: Candidate[],
  system: string,
  user: string,
  opts: AttemptOptions = {},
): AsyncGenerator<string, StreamOutcome> {
  const usable = candidates.filter((c) => c.apiKey && c.stream);
  if (usable.length === 0) {
    throw new AppError("provider_error", "No AI provider can stream.");
  }

  let last: unknown;
  for (const candidate of usable) {
    let emitted = false;
    let usage: Usage = { input_tokens: 0, output_tokens: 0 };
    try {
      for await (const chunk of candidate.stream!({
        system,
        user,
        apiKey: candidate.apiKey,
        model: candidate.model,
        temperature: opts.temperature,
        maxTokens: opts.maxTokens,
        signal: opts.signal,
        timeoutMs: opts.timeoutMs,
      })) {
        if (chunk.usage) usage = chunk.usage;
        if (!chunk.delta) continue;
        emitted = true;
        yield chunk.delta;
      }

      // A stream that ends without a single token is a failure dressed as a
      // success: the reader would be left with an empty bubble.
      if (!emitted) {
        throw new ProviderError(candidate.provider, null, true, "Empty stream.");
      }

      return { model: candidate.model, provider: candidate.provider, usage };
    } catch (err) {
      last = err;
      if (emitted) {
        // Partial answer the user already saw — settle against this provider,
        // do not burn the next rung, and let the caller mark it truncated.
        return {
          model: candidate.model,
          provider: candidate.provider,
          usage,
          truncated: true,
        };
      }
      const retryable = err instanceof ProviderError ? err.retryable : false;
      if (!retryable) break;
      console.error(
        `provider ${candidate.provider} failed before first token, trying next:`,
        (err as Error).message,
      );
    }
  }

  throw new AppError(
    "provider_error",
    last instanceof Error ? last.message : "All AI providers failed.",
  );
}

/** Tier-ordered candidates: the tier's primary first, then the shared fallback. */
export function candidatesForTier(config: AppConfig, tier: Tier): Candidate[] {
  const primary: Candidate = tier === "premium"
    ? {
      provider: "anthropic",
      generate: anthropicGenerateJson,
      stream: anthropicStreamText,
      apiKey: Deno.env.get("ANTHROPIC_API_KEY") ?? "",
      model: premiumModelId(config.str("ai_model_premium", "claude-sonnet")),
    }
    : {
      provider: "gemini",
      generate: geminiGenerateJson,
      stream: geminiStreamText,
      apiKey: Deno.env.get("GEMINI_API_KEY") ?? "",
      model: config.str("ai_model_free", "gemini-3.1-flash-lite"),
    };

  const ladder: Candidate[] = [primary, {
    provider: "openai",
    generate: openaiGenerateJson,
    stream: openaiStreamText,
    apiKey: Deno.env.get("OPENAI_API_KEY") ?? "",
    model: config.str("ai_model_fallback", "gpt-4o-mini"),
  }];

  // Optional self-hosted OpenAI-compatible endpoint (vLLM / TGI). Appended so
  // it only runs after commercial providers fail — never the default path.
  if (selfhostConfigured()) {
    ladder.push({
      provider: "selfhost",
      generate: selfhostGenerateJson,
      stream: selfhostStreamText,
      apiKey: Deno.env.get("AI_SELFHOST_API_KEY") || "not-needed",
      model: config.str("ai_model_selfhost", "local"),
    });
  }

  return ladder;
}

export function generateJson(
  config: AppConfig,
  tier: Tier,
  system: string,
  user: string,
  opts: AttemptOptions = {},
): Promise<RoutedResult> {
  return runLadder(candidatesForTier(config, tier), system, user, {
    timeoutMs: config.int("ai_provider_timeout_ms", DEFAULT_TIMEOUT_MS),
    ...opts,
  });
}

/** Streaming counterpart of `generateJson`: same tier ladder, same timeouts. */
export function streamText(
  config: AppConfig,
  tier: Tier,
  system: string,
  user: string,
  opts: AttemptOptions = {},
): AsyncGenerator<string, StreamOutcome> {
  return streamLadder(candidatesForTier(config, tier), system, user, {
    timeoutMs: config.int("ai_provider_timeout_ms", DEFAULT_TIMEOUT_MS),
    ...opts,
  });
}
