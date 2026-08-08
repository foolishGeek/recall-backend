// The embedding seam.
//
// Chat retrieval only works if a query is embedded by the same model that
// embedded the chunks, so the model is treated as a named thing with a known
// dimension rather than a loose string. Adding a self-hosted embedder later is
// one registry entry plus one case in [embedTexts] — nothing else moves.

import { AppConfig } from "../config.ts";
import { AppError } from "../errors.ts";
import { openaiEmbed } from "./openai.ts";
import { ProviderError } from "./types.ts";

export interface EmbedModel {
  id: string;
  provider: "openai";
  /** Must match the pgvector column the vectors are stored in. */
  dimensions: number;
  /** Provider cap on inputs per call. */
  batchSize: number;
}

export const EMBED_MODELS: Record<string, EmbedModel> = {
  "text-embedding-3-small": {
    id: "text-embedding-3-small",
    provider: "openai",
    dimensions: 1536,
    batchSize: 96,
  },
  "text-embedding-3-large": {
    id: "text-embedding-3-large",
    provider: "openai",
    dimensions: 3072,
    batchSize: 96,
  },
};

/** The model chunks are written with; `node_chunks.embedding` is vector(1536). */
export const DEFAULT_EMBED_MODEL = "text-embedding-3-small";

export function resolveEmbedModel(config: AppConfig): EmbedModel {
  const id = config.str("ai_model_embed", DEFAULT_EMBED_MODEL);
  const model = EMBED_MODELS[id];
  if (!model) {
    throw new AppError("provider_error", `Unknown embedding model "${id}".`);
  }
  return model;
}

export interface EmbedResult {
  embeddings: number[][];
  inputTokens: number;
  model: string;
  provider: string;
}

/**
 * Embeds any number of texts, splitting into provider-sized batches and keeping
 * input order. Throws rather than returning a short list — a caller that zipped
 * a short result back onto its chunks would attach the wrong vectors.
 */
export async function embedTexts(
  config: AppConfig,
  inputs: string[],
  signal?: AbortSignal,
): Promise<EmbedResult> {
  const model = resolveEmbedModel(config);
  const apiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  if (!apiKey) throw new AppError("provider_error", "Embedding provider key missing.");

  const embeddings: number[][] = [];
  let inputTokens = 0;

  for (let i = 0; i < inputs.length; i += model.batchSize) {
    const batch = inputs.slice(i, i + model.batchSize);
    const out = await openaiEmbed(apiKey, model.id, batch, signal);
    embeddings.push(...out.embeddings);
    inputTokens += out.inputTokens;
  }

  const wrongWidth = embeddings.find((v) => v.length !== model.dimensions);
  if (wrongWidth) {
    throw new ProviderError(
      model.provider,
      null,
      false,
      `${model.id} returned ${wrongWidth.length} dims, expected ${model.dimensions}`,
    );
  }

  return { embeddings, inputTokens, model: model.id, provider: model.provider };
}

/**
 * Embeds one retrieval query, returning null instead of throwing.
 *
 * Retrieval is an optimisation: every caller already has a corpus fallback for
 * notes that were never chunked. Letting an embedding hiccup fail the whole
 * answer would trade a slightly worse reply for no reply at all.
 */
export async function embedQuery(
  config: AppConfig,
  text: string,
  signal?: AbortSignal,
): Promise<number[] | null> {
  try {
    const out = await embedTexts(config, [text], signal);
    return out.embeddings[0] ?? null;
  } catch (err) {
    console.error("query embedding unavailable, falling back to corpus:", (err as Error).message);
    return null;
  }
}
