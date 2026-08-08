// Checks that the SSE reader reassembles events when the network splits them at
// hostile points: mid-JSON, mid-line, and mid-UTF-8 character.
// Run: deno run --allow-read tool/sse_verify.ts (from recall-backend/).

import { parseEvent, sseLines } from "../supabase/functions/_shared/providers/sse.ts";
import { isRetryableStatus } from "../supabase/functions/_shared/providers/types.ts";

function assert(cond: boolean, msg: string) {
  if (!cond) {
    console.error("FAIL", msg);
    Deno.exit(1);
  }
}

/** Serves `wire` in fixed-size byte slices, ignoring line boundaries. */
function stubFetch(wire: string, sliceBytes: number, status = 200) {
  const bytes = new TextEncoder().encode(wire);
  globalThis.fetch = () => {
    let at = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (at >= bytes.length) {
          controller.close();
          return;
        }
        controller.enqueue(bytes.slice(at, at + sliceBytes));
        at += sliceBytes;
      },
    });
    return Promise.resolve(new Response(status === 200 ? body : "nope", { status }));
  };
}

async function collect(): Promise<string[]> {
  const out: string[] = [];
  for await (const payload of sseLines({
    provider: "test",
    url: "https://example.test/stream",
    headers: {},
    body: {},
  })) {
    out.push(payload);
  }
  return out;
}

// "café" is two bytes in UTF-8, so a slice can land inside the character.
const WIRE = [
  'data: {"t":"Hello "}',
  'data: {"t":"café "}',
  ": a comment line the reader must ignore",
  'data: {"t":"world"}',
  "data: [DONE]",
].join("\n") + "\n";

for (const slice of [1, 2, 3, 7, 13, 64, 4096]) {
  stubFetch(WIRE, slice);
  const payloads = await collect();
  const texts = payloads
    .map((p) => parseEvent<{ t: string }>(p))
    .filter((f): f is { t: string } => !!f)
    .map((f) => f.t)
    .join("");
  assert(texts === "Hello café world", `events reassemble at slice ${slice} (got "${texts}")`);
  assert(payloads.length === 4, `[DONE] is delivered as a payload at slice ${slice}`);
  assert(parseEvent("[DONE]") === null, "[DONE] parses to nothing");
}

// A final event with no trailing newline must not be dropped.
stubFetch('data: {"t":"tail"}', 4);
const tail = await collect();
assert(tail.length === 1 && tail[0].includes("tail"), "unterminated last event still arrives");

// A retired model (404) has to stay retryable, or the ladder never reaches the
// fallback — the exact failure that took summarize down.
stubFetch("", 4, 404);
let status: number | null = null;
let retryable = false;
try {
  await collect();
} catch (e) {
  const err = e as { status: number | null; retryable: boolean };
  status = err.status;
  retryable = err.retryable;
}
assert(status === 404, "a 404 surfaces as a ProviderError with its status");
assert(retryable, "a 404 falls through to the next provider");
assert(!isRetryableStatus(413), "an oversized prompt still stops the ladder");

console.log("OK sse_verify");
