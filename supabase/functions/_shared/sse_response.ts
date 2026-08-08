// Writing Server-Sent Events back to the app.
//
// Errors are split by when they happen. Anything decided before the first byte —
// quota, cooldown, a bad payload — stays a normal JSON error response with its
// real status code, because that is what the client's error mapping expects.
// Only a failure *after* the stream has opened becomes an `error` event, since
// by then the status line is long gone.

import { corsHeaders } from "./cors.ts";

export const sseHeaders: Record<string, string> = {
  ...corsHeaders,
  "Content-Type": "text/event-stream; charset=utf-8",
  "Cache-Control": "no-cache, no-transform",
  Connection: "keep-alive",
  // Tells any proxy in between not to buffer the body, which would collect the
  // whole answer and deliver it at once — the exact thing streaming avoids.
  "X-Accel-Buffering": "no",
};

/** Serialises one named SSE event. */
export function sseEvent(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

/**
 * Builds a streaming Response from a writer function.
 *
 * The writer is handed an `emit` that is safe to call after the client has gone:
 * a disconnected controller throws on enqueue, and a half-written answer is
 * still worth saving, so the write is dropped rather than taking down the
 * bookkeeping that follows it.
 */
/**
 * Builds a streaming Response from a writer function.
 *
 * [signal] is aborted when the client disconnects (ReadableStream cancel) so
 * the provider fetch stops instead of burning tokens into the void. Bookkeeping
 * after the first token still runs — a partial answer the user already saw is
 * worth saving, and the settle must close the reservation.
 */
export function sseResponse(
  write: (
    emit: (event: string, data: unknown) => void,
    signal: AbortSignal,
  ) => Promise<void>,
  outer?: AbortSignal,
): Response {
  const encoder = new TextEncoder();
  const local = new AbortController();
  const onOuter = () => local.abort();
  outer?.addEventListener("abort", onOuter);
  if (outer?.aborted) local.abort();

  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      let open = true;
      const emit = (event: string, data: unknown) => {
        if (!open) return;
        try {
          controller.enqueue(encoder.encode(sseEvent(event, data)));
        } catch {
          open = false;
          local.abort();
        }
      };

      try {
        await write(emit, local.signal);
      } catch (err) {
        console.error("sse writer failed:", (err as Error).message);
      } finally {
        open = false;
        outer?.removeEventListener("abort", onOuter);
        try {
          controller.close();
        } catch {
          // Already closed by the client disconnecting.
        }
      }
    },
    cancel() {
      local.abort();
    },
  });

  return new Response(body, { headers: sseHeaders });
}
