// One HTTP path for every provider call.
//
// Without a timeout a hung provider holds the isolate until the platform kills
// it, and a killed isolate never settles its reservation — the sweeper would
// have to clean up something we could have failed cleanly. So every call gets a
// deadline, and every failure is classified as retryable or not.

import { isRetryableStatus, ProviderError } from "./types.ts";

export const DEFAULT_TIMEOUT_MS = 45_000;

export interface PostJsonArgs {
  provider: string;
  url: string;
  headers: Record<string, string>;
  body: unknown;
  timeoutMs?: number;
  /** Caller's deadline; aborts this request too. */
  signal?: AbortSignal;
}

export async function postJson(args: PostJsonArgs): Promise<unknown> {
  const timeoutMs = args.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const timer = new AbortController();
  const timeout = setTimeout(() => timer.abort(), timeoutMs);
  const onOuterAbort = () => timer.abort();
  args.signal?.addEventListener("abort", onOuterAbort);

  try {
    const res = await fetch(args.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...args.headers },
      body: JSON.stringify(args.body),
      signal: timer.signal,
    });

    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new ProviderError(
        args.provider,
        res.status,
        isRetryableStatus(res.status),
        `${args.provider} ${res.status}: ${text.slice(0, 200)}`,
      );
    }
    return await res.json();
  } catch (err) {
    if (err instanceof ProviderError) throw err;
    // An abort is either our timeout or the caller giving up; both are worth
    // trying elsewhere, and network errors are transient by nature.
    const aborted = err instanceof DOMException && err.name === "AbortError";
    throw new ProviderError(
      args.provider,
      null,
      true,
      aborted
        ? `${args.provider} timed out after ${timeoutMs}ms`
        : `${args.provider} request failed: ${(err as Error).message}`,
    );
  } finally {
    clearTimeout(timeout);
    args.signal?.removeEventListener("abort", onOuterAbort);
  }
}
