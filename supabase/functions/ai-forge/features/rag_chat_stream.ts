// Feature: rag_chat_stream — the same answer as rag_chat, delivered as it is
// written.
//
// Two things make this more than "the buffered path with yields". The quota
// decision has to be made before the response starts, so a denial is still a
// real 403 the client already knows how to read; and the citations cannot ride
// along inside JSON, so they arrive as a trailer the reader never sees
// (stream_trailer.ts) and are replayed in the closing `done` event.
//
// The user is charged when an answer is delivered. A provider that fails before
// the first token releases the hold and falls through to the next provider; one
// that fails after it keeps the partial answer, saves it, and settles — the user
// got something, and the tokens were really spent.

import { AppConfig } from "../../_shared/config.ts";
import { AppError } from "../../_shared/errors.ts";
import { registerPrompt } from "../../_shared/prompt_registry.ts";
import { streamText } from "../../_shared/providers/route.ts";
import { openMeteredRequest } from "../../_shared/quota.ts";
import { sseResponse } from "../../_shared/sse_response.ts";
import {
  CitationTrailer,
  refsToNodeIds,
  sourceIndex,
} from "../../_shared/stream_trailer.ts";
import { userDirectives } from "../../_shared/user_prefs.ts";
import { RAG_STREAM_SYSTEM } from "../prompts.ts";
import {
  buildUserPrompt,
  CitationNode,
  finishTurn,
  prepareChat,
  PreparedChat,
  resolveCitations,
} from "./chat_core.ts";

export async function ragChatStream(
  payload: Record<string, unknown>,
  userId: string,
  config: AppConfig,
  signal?: AbortSignal,
): Promise<Response> {
  const prepared = await prepareChat(payload, userId, config);
  const prompt = await registerPrompt("rag_chat_stream", RAG_STREAM_SYSTEM);

  // Before the first byte, so a quota denial is a JSON 403 and not an event.
  const hold = await openMeteredRequest(prepared.meter);
  if (hold.replay !== undefined) return replayResponse(hold.replay);

  const system = RAG_STREAM_SYSTEM + (await userDirectives(userId));
  const sources = prepared.ctx.nodes;
  const userPrompt = buildUserPrompt(
    prepared,
    sources.length > 0 ? `SOURCES (cite by number):\n${sourceIndex(sources)}` : "",
  );

  return sseResponse(async (emit, streamSignal) => {
    emit("open", { notes: sources.length });

    const trailer = new CitationTrailer();
    const stream = streamText(config, prepared.tier, system, userPrompt, {
      temperature: hold.reservation.temperature,
      maxTokens: hold.reservation.maxTokens,
      signal: streamSignal,
    });

    let answer = "";
    const t0 = Date.now();
    let failure: unknown = null;
    let model = "";
    let provider = "";
    let usage = { input_tokens: 0, output_tokens: 0 };

    try {
      // The generator's return value carries which provider actually answered,
      // so it has to be driven by hand — for..of throws it away.
      while (true) {
        const step = await stream.next();
        if (step.done) {
          model = step.value.model;
          provider = step.value.provider;
          usage = step.value.usage;
          break;
        }
        const safe = trailer.push(step.value);
        if (!safe) continue;
        answer += safe;
        emit("delta", { t: safe });
      }
    } catch (err) {
      failure = err;
    }

    const { tail, refs } = trailer.end();
    if (tail) {
      answer += tail;
      emit("delta", { t: tail });
    }

    // Nothing delivered: release the hold and report it like any other failure.
    if (!answer.trim()) {
      await hold.failed(failure ?? new AppError("provider_error"));
      emit("error", errorPayload(failure));
      return;
    }

    const citations = resolveCitations(prepared.ctx, refsToNodeIds(refs, sources));
    const latencyMs = Date.now() - t0;

    const saved = await persist(prepared, hold, {
      answer,
      citations,
      model,
      provider,
      usage,
      latencyMs,
      promptId: prompt.promptId,
      systemPromptSha: prompt.sha,
    });

    if (failure) {
      // A truncated answer is still an answer, but the reader deserves to know
      // it stopped early rather than being left mid-sentence.
      emit("error", { ...errorPayload(failure), partial: true });
    }

    emit("done", {
      answer,
      citations,
      model,
      usage,
      interaction_id: saved.interactionId,
      conversation_id: saved.conversationId,
    });
  }, signal);
}

interface StreamedTurn {
  answer: string;
  citations: CitationNode[];
  model: string;
  provider: string;
  usage: { input_tokens: number; output_tokens: number };
  latencyMs: number;
  promptId: string | null;
  systemPromptSha: string;
}

/**
 * Saves the turn and closes the hold.
 *
 * The settle comes last and is never skipped: an answer the user has already
 * read must not stay an open reservation, and if the isolate dies here the
 * ai_sweep_stale_requests cron releases it rather than the user losing a unit.
 */
async function persist(
  prepared: PreparedChat,
  hold: Awaited<ReturnType<typeof openMeteredRequest>>,
  turn: StreamedTurn,
): Promise<{ interactionId: string | null; conversationId: string | null }> {
  let saved: { interactionId: string | null; conversationId: string } | null = null;
  try {
    saved = await finishTurn(prepared, hold.reservation, { ...turn, streamed: true });
  } catch (e) {
    console.error("finishTurn failed after streaming:", (e as Error).message);
  }

  // Cache the closing frame so a retried client_request_id replays instead of
  // re-charging and regenerating — same guarantee as the buffered path.
  const result = {
    answer: turn.answer,
    citations: turn.citations,
    model: turn.model,
    usage: turn.usage,
    interaction_id: saved?.interactionId ?? null,
    conversation_id: saved?.conversationId ?? prepared.conversationId,
  };
  await hold.succeeded({
    model: turn.model,
    provider: turn.provider,
    inputTokens: turn.usage.input_tokens,
    outputTokens: turn.usage.output_tokens,
    cacheResponse: true,
    result,
  });

  return saved ?? { interactionId: null, conversationId: prepared.conversationId };
}

function errorPayload(err: unknown): Record<string, unknown> {
  if (err instanceof AppError) {
    return { error: err.code, message: err.message, ...(err.extra ?? {}) };
  }
  return { error: "provider_error", message: "The answer stopped early. Try again." };
}

/**
 * An idempotent retry of a request we already answered. The text is replayed in
 * one frame — re-typing a known answer would be theatre, and the client only
 * needs the same events in the same order.
 */
function replayResponse(cached: unknown): Response {
  const body = (cached ?? {}) as Record<string, unknown>;
  const answer = typeof body.answer === "string" ? body.answer : "";
  return sseResponse((emit) => {
    emit("open", { notes: Array.isArray(body.citations) ? body.citations.length : 0 });
    if (answer) emit("delta", { t: answer });
    emit("done", body);
    return Promise.resolve();
  });
}
