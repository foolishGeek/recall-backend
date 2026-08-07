// Feature: embed [D-EF-4]. No LLM. The work lives in _shared/embed_node.ts
// because the embed-drain cron worker runs the same thing; this is only the
// router's entry point into it.

import { AppConfig } from "../../_shared/config.ts";
import { embedNode, EmbedResult } from "../../_shared/embed_node.ts";
import { requireUuid } from "../../_shared/validate.ts";

export type { EmbedResult };

export function embed(payload: Record<string, unknown>, config: AppConfig): Promise<EmbedResult> {
  return embedNode(requireUuid(payload.node_id, "node_id"), config);
}
