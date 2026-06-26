// WebContextProvider [D-AI-7]. Freehand quiz blends the user's notes with the
// model's general knowledge "about the topics collectively". This is the seam
// for live web search/grounding later. It is a NO-OP today (returns nothing),
// so freehand relies on notes + the model's trained knowledge for now. Plug a
// search API here (returning { text, sources }) to enable live grounding.

import { AppConfig } from "./config.ts";

export interface WebContextResult {
  text: string;
  sources: string[];
}

// deno-lint-ignore no-unused-vars
export async function webContext(query: string, config: AppConfig): Promise<WebContextResult> {
  // Future: if app_config.ai_web_search_enabled and a provider key is set,
  // call the search API, summarize the top results, and return them here.
  return await Promise.resolve({ text: "", sources: [] });
}
