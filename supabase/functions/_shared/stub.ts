// Shared handler for deploy-shell Edge Functions. The route exists and returns a
// clear stub so it's wired now; the full contract lands in the owning sprint.

import { handlePreflight } from "./cors.ts";
import { jsonResponse } from "./errors.ts";

export function stubFunction(name: string, sprint: string): void {
  Deno.serve((req) => {
    const pre = handlePreflight(req);
    if (pre) return pre;
    return jsonResponse({
      stub: true,
      function: name,
      sprint,
      message: `${name} is a deploy shell; full logic lands in ${sprint}.`,
    });
  });
}
