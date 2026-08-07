// dataset-export — stub. Authenticated by service-role JWT or X-Cron-Secret.
// Writes nothing yet; documents the intended manifest layout for a future
// job that dumps ai_dataset_items as versioned JSONL into storage.ai-datasets.
//
// Intended layout (not written by this stub):
//   ai-datasets/{dataset_name}/{version}/part-00001.jsonl
//   ai-datasets/{dataset_name}/{version}/manifest.json
//     { row_counts, filters, code_revision, exported_at }

import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/errors.ts";
import { resolveCaller } from "../_shared/auth.ts";

/** Constant-time string compare to avoid leaking the secret via timing. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function authorized(req: Request): boolean {
  try {
    const caller = resolveCaller(req);
    if (caller.isServiceRole) return true;
  } catch {
    // Fall through to cron secret.
  }
  const expected = Deno.env.get("CRON_SECRET") ?? "";
  const provided = req.headers.get("X-Cron-Secret") ?? "";
  return !!expected && safeEqual(provided, expected);
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  if (!authorized(req)) {
    return new Response(
      JSON.stringify({ error: "unauthorized", message: "Service role or cron secret required." }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  // Placeholder: a real export would stream JSONL parts + a manifest.json into
  // the private `ai-datasets` bucket. Schema + storage bucket exist (00070);
  // training is explicitly out of scope for this stub.
  return jsonResponse({
    status: "stub",
    message: "dataset-export is not implemented yet.",
    // manifest comment for operators reading the response / source:
    // { dataset, version, row_counts: { train, validation, test },
    //   filters, code_revision, exported_at, parts: ["part-00001.jsonl"] }
  });
});
