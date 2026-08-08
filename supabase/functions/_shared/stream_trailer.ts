// Citations on a streamed answer.
//
// A buffered reply can be JSON, so the answer and its citations arrive together.
// A streamed reply cannot: the user is reading it as it is written, and JSON is
// unreadable until the closing brace. So the model writes prose and then, on the
// last line, a machine-readable trailer:
//
//   <<<CITES: 1, 3>>>
//
// Two things have to be true for this to be safe. The reader must never see any
// part of the trailer, including the moment a chunk ends mid-marker — so text
// that could still turn out to be the start of the marker is held back until the
// next chunk proves otherwise. And a model that forgets the trailer, or invents
// a source number, must cost the user nothing worse than missing source chips.

export const CITE_MARK = "<<<CITES:";

/**
 * Splits a token stream into displayable prose and a trailing citation marker.
 *
 * `push` returns only text that is safe to show; anything that might be the
 * beginning of the marker stays in the buffer.
 */
export class CitationTrailer {
  private held = "";
  private trailer = "";
  private closed = false;

  push(delta: string): string {
    if (this.closed) {
      this.trailer += delta;
      return "";
    }

    this.held += delta;

    const at = this.held.indexOf(CITE_MARK);
    if (at !== -1) {
      const safe = this.held.slice(0, at);
      this.trailer = this.held.slice(at);
      this.held = "";
      this.closed = true;
      return safe;
    }

    // The buffer may end on a partial marker ("…done.<<<CI"). Hold back the
    // longest suffix that is still a prefix of the marker; emitting it now and
    // discovering the rest next chunk is exactly the leak this class prevents.
    const hold = partialMarkerLength(this.held);
    if (hold === 0) {
      const safe = this.held;
      this.held = "";
      return safe;
    }

    const safe = this.held.slice(0, this.held.length - hold);
    this.held = this.held.slice(this.held.length - hold);
    return safe;
  }

  /**
   * Ends the stream. Any held-back text that never became a marker is real
   * answer text and is returned; source numbers are parsed from the trailer.
   */
  end(): { tail: string; refs: number[] } {
    const tail = this.held;
    this.held = "";
    return { tail, refs: parseRefs(this.trailer) };
  }
}

/** Length of the longest suffix of `text` that is a proper prefix of the marker. */
function partialMarkerLength(text: string): number {
  const max = Math.min(text.length, CITE_MARK.length - 1);
  for (let k = max; k > 0; k--) {
    if (text.endsWith(CITE_MARK.slice(0, k))) return k;
  }
  return 0;
}

/** Pulls the source numbers out of "<<<CITES: 1, 3>>>". Junk yields nothing. */
export function parseRefs(trailer: string): number[] {
  if (!trailer) return [];
  const body = trailer.slice(trailer.indexOf(CITE_MARK) + CITE_MARK.length)
    .replace(/>+\s*$/, "");
  const seen = new Set<number>();
  for (const token of body.split(/[^0-9]+/)) {
    if (!token) continue;
    const n = Number(token);
    if (Number.isInteger(n) && n > 0) seen.add(n);
  }
  return [...seen];
}

/**
 * Maps the model's source numbers back to node ids.
 *
 * Anything out of range is dropped rather than guessed: a wrong chip sends the
 * user to a note that does not support the sentence they tapped, which is worse
 * than no chip at all.
 */
export function refsToNodeIds(refs: number[], sources: { node_id: string }[]): string[] {
  const ids: string[] = [];
  for (const ref of refs) {
    const source = sources[ref - 1];
    if (source && !ids.includes(source.node_id)) ids.push(source.node_id);
  }
  return ids;
}

/** The numbered source list the model cites against. */
export function sourceIndex(sources: { title: string }[]): string {
  return sources
    .map((s, i) => `${i + 1}. ${s.title?.trim() || "Untitled"}`)
    .join("\n");
}
