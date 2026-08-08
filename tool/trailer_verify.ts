// Checks that the citation trailer never leaks into the text the user reads,
// including when the marker is split across chunk boundaries.
// Run: deno run --allow-read tool/trailer_verify.ts (from recall-backend/).

import {
  CITE_MARK,
  CitationTrailer,
  parseRefs,
  refsToNodeIds,
} from "../supabase/functions/_shared/stream_trailer.ts";

function assert(cond: boolean, msg: string) {
  if (!cond) {
    console.error("FAIL", msg);
    Deno.exit(1);
  }
}

/** Feeds a full reply through the splitter in chunks of `size` characters. */
function run(reply: string, size: number): { shown: string; refs: number[] } {
  const trailer = new CitationTrailer();
  let shown = "";
  for (let i = 0; i < reply.length; i += size) {
    shown += trailer.push(reply.slice(i, i + size));
  }
  const end = trailer.end();
  return { shown: shown + end.tail, refs: end.refs };
}

const ANSWER = "Ser is permanent, estar is temporary.\n\nMore broadly, this is common.";
const REPLY = `${ANSWER}\n${CITE_MARK} 1, 3>>>`;

// Every chunk size, including one character at a time — the worst case for a
// marker straddling a boundary.
for (let size = 1; size <= REPLY.length; size++) {
  const { shown, refs } = run(REPLY, size);
  assert(!shown.includes("<<<"), `no marker leaks at chunk size ${size}`);
  assert(!shown.includes("CITES"), `no marker text leaks at chunk size ${size}`);
  assert(shown.trim() === ANSWER.trim(), `answer survives intact at chunk size ${size}`);
  assert(
    refs.length === 2 && refs[0] === 1 && refs[1] === 3,
    `refs parsed at chunk size ${size}`,
  );
}

// A model that forgets the trailer still gets its whole answer shown.
const forgot = run(ANSWER, 7);
assert(forgot.shown === ANSWER, "no trailer means nothing is swallowed");
assert(forgot.refs.length === 0, "no trailer means no citations");

// Angle brackets that never become the marker must be released, not eaten.
const brackets = run("compare a <<< b and c", 3);
assert(brackets.shown === "compare a <<< b and c", "stray angle brackets survive");

// An empty citation list is a valid answer from general knowledge.
assert(parseRefs(`${CITE_MARK} >>>`).length === 0, "empty trailer yields no refs");
assert(parseRefs("").length === 0, "missing trailer yields no refs");
assert(parseRefs(`${CITE_MARK} 2,2,5>>>`).join(",") === "2,5", "duplicate refs collapse");

// Numbers the context cannot back are dropped rather than guessed.
const sources = [{ node_id: "a", title: "A" }, { node_id: "b", title: "B" }];
assert(refsToNodeIds([1, 2], sources).join(",") === "a,b", "in-range refs map to nodes");
assert(refsToNodeIds([9], sources).length === 0, "out-of-range ref is dropped");
assert(refsToNodeIds([2, 2], sources).join(",") === "b", "repeated ref cites once");

console.log("OK trailer_verify");
