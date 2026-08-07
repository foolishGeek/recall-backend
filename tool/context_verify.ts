// Quick check that formatContext keeps more than one chunk per note and
// respects the per-note cap. Run: deno run --allow-read tool/context_verify.ts
// (from recall-backend/).

import {
  diversify,
  formatContext,
  RetrievedChunk,
} from "../supabase/functions/_shared/context.ts";

function assert(cond: boolean, msg: string) {
  if (!cond) {
    console.error("FAIL", msg);
    Deno.exit(1);
  }
}

const chunks: RetrievedChunk[] = [];
for (let i = 0; i < 6; i++) {
  chunks.push({
    node_id: "pdf-1",
    title: "Long PDF",
    content: `PDF section ${i} `.repeat(20),
    similarity: 0.9 - i * 0.05,
  });
}
for (let i = 0; i < 3; i++) {
  chunks.push({
    node_id: "note-2",
    title: "Short note",
    content: `Short ${i}`,
    similarity: 0.7 - i * 0.05,
  });
}

const diversified = diversify(chunks, 3);
assert(diversified.filter((c) => c.node_id === "pdf-1").length === 3, "cap pdf at 3");
assert(diversified.filter((c) => c.node_id === "note-2").length === 3, "cap note at 3");
assert(diversified[0].node_id === "pdf-1", "strongest overall leads");

const formatted = formatContext(chunks, { maxChars: 5000, maxChunksPerNode: 2 });
assert(formatted.used.filter((c) => c.node_id === "pdf-1").length === 2, "format keeps 2 from pdf");
assert(formatted.nodes.length === 2, "two notes cited");
assert(formatted.text.includes("PDF section"), "pdf body present");

// Old one-chunk-per-note behaviour would have kept only the best of pdf-1.
assert(
  (formatted.text.match(/PDF section/g) ?? []).length >= 2,
  "long doc contributes more than one snippet",
);

console.log("PASS context diversity");
