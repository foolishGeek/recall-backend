// Reading Server-Sent Events from a provider response.
//
// All three providers stream SSE, and all three would be broken by the same
// naive mistake: a network chunk is not a line. A single read can end halfway
// through a JSON payload, or carry three events at once, so the tail of every
// chunk has to be held back until its newline arrives.

import { isRetryableStatus, ProviderError } from "./types.ts";

export interface SseOpenArgs {
  provider: string;
  url: string;
  headers: Record<string, string>;
  body: unknown;
  signal?: AbortSignal;
  timeoutMs?: number;
}

/**
 * Opens an SSE request and yields the payload of each `data:` line.
 *
 * The timeout guards the connection and the gaps between events, not the whole
 * response: a long answer legitimately takes longer than any single deadline,
 * but silence from the provider means the stream is dead. The timer is reset by
 * every event.
 */
export async function* sseLines(args: SseOpenArgs): AsyncGenerator<string> {
  const timeoutMs = args.timeoutMs ?? 45_000;
  const control = new AbortController();
  const onOuterAbort = () => control.abort();
  args.signal?.addEventListener("abort", onOuterAbort);

  let idle: ReturnType<typeof setTimeout> | undefined;
  const resetIdle = () => {
    if (idle !== undefined) clearTimeout(idle);
    idle = setTimeout(() => control.abort(), timeoutMs);
  };

  try {
    resetIdle();
    const res = await fetch(args.url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        ...args.headers,
      },
      body: JSON.stringify(args.body),
      signal: control.signal,
    });

    if (!res.ok || !res.body) {
      const text = await res.text().catch(() => "");
      throw new ProviderError(
        args.provider,
        res.status,
        // Same classification as buffered calls, so a retired model still falls
        // through to the next provider when streaming.
        isRetryableStatus(res.status),
        `${args.provider} ${res.status}: ${text.slice(0, 200)}`,
      );
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      resetIdle();
      buffer += decoder.decode(value, { stream: true });

      // Everything up to the last newline is complete; the remainder is a
      // partial line and must wait for the next read.
      let cut = buffer.indexOf("\n");
      while (cut !== -1) {
        const line = buffer.slice(0, cut).trim();
        buffer = buffer.slice(cut + 1);
        cut = buffer.indexOf("\n");
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload) yield payload;
      }
    }

    const tail = buffer.trim();
    if (tail.startsWith("data:")) {
      const payload = tail.slice(5).trim();
      if (payload) yield payload;
    }
  } catch (err) {
    if (err instanceof ProviderError) throw err;
    const aborted = err instanceof DOMException && err.name === "AbortError";
    // Our idle timer and the caller's cancel both abort the same controller.
    // Only the idle case is worth trying another provider — a user who hung up
    // (or Stop) must not burn the fallback ladder.
    const callerCancelled = aborted && args.signal?.aborted === true;
    throw new ProviderError(
      args.provider,
      null,
      aborted && !callerCancelled,
      callerCancelled
        ? `${args.provider} stream cancelled`
        : aborted
        ? `${args.provider} stream stalled for ${timeoutMs}ms`
        : `${args.provider} stream failed: ${(err as Error).message}`,
    );
  } finally {
    if (idle !== undefined) clearTimeout(idle);
    args.signal?.removeEventListener("abort", onOuterAbort);
  }
}

/** Parses an SSE payload, ignoring the frames that are not JSON (e.g. [DONE]). */
export function parseEvent<T>(payload: string): T | null {
  if (payload === "[DONE]") return null;
  try {
    return JSON.parse(payload) as T;
  } catch {
    return null;
  }
}
