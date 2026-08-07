// dataset-export. Authenticated by service-role JWT or X-Cron-Secret.
//
// POST { dataset, task?, version?, since?, limit?, build? }
//   build !== false → top up the dataset from v_ai_training_examples first
//   then write immutable JSONL parts + manifest.json to the private
//   ai-datasets bucket:
//     ai-datasets/{dataset}/{version}/part-00001.jsonl
//     ai-datasets/{dataset}/{version}/manifest.json
//
// Immutable on purpose: an export never overwrites an existing version, because
// a run you cannot reproduce is not a run. Re-export with a new version.

import { handlePreflight } from "../_shared/cors.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { adminClient } from "../_shared/supabase.ts";
import { requireString } from "../_shared/validate.ts";

const BUCKET = "ai-datasets";
const ROWS_PER_PART = 5000;

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

interface ItemRow {
  example: Record<string, unknown>;
  split: string;
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

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;

    const dataset = requireString(body.dataset, "dataset");
    const version = typeof body.version === "string" && body.version ? body.version : "v1";
    const task = typeof body.task === "string" ? body.task : null;
    const since = typeof body.since === "string" ? body.since : null;
    const limit = typeof body.limit === "number" ? body.limit : 50000;
    const db = adminClient();

    // Refuse to overwrite a published version.
    const prefix = `${dataset}/${version}`;
    const { data: existing } = await db.storage.from(BUCKET).list(prefix, { limit: 1 });
    if (existing && existing.length > 0) {
      throw new AppError(
        "invalid_input",
        `${prefix} already exists. Exports are immutable — use a new version.`,
      );
    }

    let built: unknown = null;
    if (body.build !== false) {
      if (!task) throw new AppError("invalid_input", "task is required to build a dataset");
      const { data, error } = await db.rpc("ai_dataset_build", {
        p_name: dataset,
        p_task: task,
        p_version: version,
        p_since: since,
        p_limit: limit,
      });
      if (error) throw error;
      built = data;
    }

    const { data: ds, error: dsErr } = await db
      .from("ai_datasets")
      .select("id, name, task, version")
      .eq("name", dataset)
      .eq("version", version)
      .maybeSingle();
    if (dsErr) throw dsErr;
    if (!ds) throw new AppError("invalid_input", "dataset not found");

    // Page through items so a large dataset does not have to fit in memory at
    // once; each page becomes one JSONL part.
    const counts: Record<string, number> = { train: 0, validation: 0, test: 0 };
    const parts: string[] = [];
    let offset = 0;
    let total = 0;

    for (;;) {
      const { data: items, error: iErr } = await db
        .from("ai_dataset_items")
        .select("example, split")
        .eq("dataset_id", ds.id)
        .order("created_at", { ascending: true })
        .range(offset, offset + ROWS_PER_PART - 1);
      if (iErr) throw iErr;

      const rows = (items ?? []) as ItemRow[];
      if (rows.length === 0) break;

      const jsonl = rows.map((r) => JSON.stringify(r.example)).join("\n") + "\n";
      const name = `part-${String(parts.length + 1).padStart(5, "0")}.jsonl`;
      const { error: upErr } = await db.storage
        .from(BUCKET)
        .upload(`${prefix}/${name}`, new TextEncoder().encode(jsonl), {
          contentType: "application/x-ndjson",
          upsert: false,
        });
      if (upErr) throw upErr;

      for (const r of rows) counts[r.split] = (counts[r.split] ?? 0) + 1;
      parts.push(name);
      total += rows.length;
      offset += ROWS_PER_PART;
      if (rows.length < ROWS_PER_PART) break;
    }

    const manifest = {
      dataset,
      version,
      task: ds.task,
      dataset_id: ds.id,
      row_counts: { ...counts, total },
      parts,
      filters: { task, since, limit },
      // Set by the deploy so an export can be tied back to the code that made it.
      code_revision: Deno.env.get("CODE_REVISION") ?? null,
      exported_at: new Date().toISOString(),
      example_schema: [
        "id",
        "task",
        "input",
        "context",
        "output",
        "signals",
        "labels",
        "provenance",
        "split",
      ],
    };

    const { error: mErr } = await db.storage
      .from(BUCKET)
      .upload(
        `${prefix}/manifest.json`,
        new TextEncoder().encode(JSON.stringify(manifest, null, 2)),
        { contentType: "application/json", upsert: false },
      );
    if (mErr) throw mErr;

    return jsonResponse({ status: "ok", built, manifest });
  } catch (err) {
    console.error("dataset-export error:", (err as Error)?.message);
    return toErrorResponse(err);
  }
});
