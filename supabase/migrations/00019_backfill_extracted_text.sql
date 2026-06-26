-- Sprint: Aura AI engine. RAG had an empty corpus because legacy nodes were
-- saved without extracted_text (the embed trigger early-returns on empty text),
-- so nothing was ever embedded. Backfill a best-effort corpus for those nodes
-- (mirrors _shared/node_corpus.ts: title + markdown + link preview + url) and
-- bump content_hash so the existing on_node_content_hash_change trigger fires
-- the embed pipeline. Future saves already persist extracted_text from the app.
-- Tie-breaker: Roadmap/sprints/CANON-DECISIONS.md [D-EF-4].

WITH corpus AS (
  SELECT
    n.id,
    btrim(concat_ws(
      E'\n',
      nullif(btrim(coalesce(n.title, '')), ''),
      nullif(btrim(coalesce(n.markdown, '')), ''),
      nullif(btrim(coalesce(n.link_preview_json->>'title', '')), ''),
      nullif(btrim(coalesce(n.link_preview_json->>'description', '')), ''),
      nullif(btrim(coalesce(n.link_preview_json->>'site_name', '')), ''),
      nullif(btrim(coalesce(n.url, '')), '')
    )) AS text
  FROM nodes n
  WHERE coalesce(n.extracted_text, '') = ''
    AND n.deleted_at IS NULL
)
UPDATE nodes n
SET extracted_text = c.text,
    content_hash = md5(c.text)
FROM corpus c
WHERE n.id = c.id
  AND c.text <> '';
