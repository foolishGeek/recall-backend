// ai-forge — one router keyed by `feature` [CANON §13.4]. Accepts
// POST { feature, payload }. The embed pipeline calls it with the service-role
// key (DB trigger); user features call it with a user JWT. All quota, model
// routing, retrieval scope, and tier decisions happen here / in the gate RPCs.

import { handlePreflight } from "../_shared/cors.ts";
import { AppError, jsonResponse, toErrorResponse } from "../_shared/errors.ts";
import { resolveCaller } from "../_shared/auth.ts";
import { AppConfig } from "../_shared/config.ts";
import { embed } from "./features/embed.ts";
import { ragChat } from "./features/rag_chat.ts";
import { summarize } from "./features/summarize.ts";
import { evaluate } from "./features/evaluate.ts";
import { quizGenerate } from "./features/quiz_generate.ts";
import { quizGrade } from "./features/quiz_grade.ts";

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  try {
    if (req.method !== "POST") throw new AppError("invalid_input", "POST only");

    const caller = resolveCaller(req);
    const body = await req.json().catch(() => ({}));
    const feature = (body as { feature?: string }).feature;
    const payload = ((body as { payload?: Record<string, unknown> }).payload ?? {}) as Record<string, unknown>;
    if (!feature) throw new AppError("invalid_input", "feature is required");

    const config = await AppConfig.load();

    // Resolves the acting user for user-scoped features. embed resolves the
    // owner from the node itself, so it allows service-role (no user) callers.
    const requireUser = (): string => {
      if (!caller.userId) throw new AppError("unauthorized");
      return caller.userId;
    };

    switch (feature) {
      case "embed":
        return jsonResponse(await embed(payload, config));
      case "rag_chat":
        return jsonResponse(await ragChat(payload, requireUser(), config));
      case "summarize":
        return jsonResponse(await summarize(payload, requireUser(), config));
      case "evaluate":
        return jsonResponse(await evaluate(payload, requireUser(), config));
      case "quiz_generate":
        return jsonResponse(await quizGenerate(payload, requireUser(), config));
      case "quiz_grade":
        return jsonResponse(await quizGrade(payload, requireUser(), config));
      default:
        throw new AppError("invalid_input", `unknown feature: ${feature}`);
    }
  } catch (err) {
    return toErrorResponse(err);
  }
});
