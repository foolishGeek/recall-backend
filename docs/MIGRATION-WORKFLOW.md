# Migration workflow — staging → prod

Canon: migrations apply **staging first**, smoke test, then **prod**. Final prod verification in S27.

---

## Prerequisites

- `npx supabase login` (or `SUPABASE_ACCESS_TOKEN`)
- CLI linked to staging: `npx supabase link --project-ref <staging-ref>`
- Migrations live in `supabase/migrations/` (owned by S01+)

---

## Standard flow

### 1. Author migration

Add a new timestamped SQL file under `supabase/migrations/`.

### 2. Apply to staging

```bash
cd recall-backend
npx supabase link --project-ref <staging-ref>   # if not already linked
npx supabase db push
```

### 3. Smoke test staging

- Exercise affected flows on staging build (`ENV=staging` dart-defines).
- Check Supabase logs / advisors if something fails.

### 4. Apply to production

```bash
npx supabase link --project-ref <prod-ref>
npx supabase db push
```

Re-link to staging when done if that is your daily driver:

```bash
npx supabase link --project-ref <staging-ref>
```

### 5. Ship gate (S27)

- Confirm prod schema matches staging.
- Re-run critical user paths on prod flavor.

---

## Rules

- **Never** push untested migrations directly to prod.
- **Never** commit service role keys or `.env` with secrets.
- Edge Functions deploy separately (`supabase functions deploy`) in their owner sprints.
- Extension enablement (`pg_cron`, `pg_net`, `vector`, `pgcrypto`) is S00 — see `scripts/sql/enable-extensions.sql`.

---

## Embed trigger database settings (required for `[D-EF-4]`)

The S01 `on_node_content_hash_change` trigger POSTs to the `ai-forge` `embed` function via `pg_net`.
It reads two database-level GUCs and **silently no-ops** (returns the row unchanged, no POST) when
either is unset — so on a fresh project the trigger does nothing until these are configured. Set them
once per project (run as the owner; substitute the project's real values):

```sql
ALTER DATABASE postgres SET app.supabase_url = 'https://<project-ref>.supabase.co';
ALTER DATABASE postgres SET app.service_role_key = '<service-role-jwt>';
-- new sessions pick these up; reconnect (or SELECT pg_reload_conf()) to apply
```

- The `embed` call only fires once `ai-forge` is deployed (S06). Until then, leaving these unset (or
  set) is harmless — the trigger degrades gracefully and re-fires on the next `content_hash` change.
- **Security:** `app.service_role_key` lives in the DB config and is readable by superusers / roles
  with config access. Treat it as a secret: never commit it, never echo it into migration files,
  and rotate it if exposed. The trigger function is `SECURITY DEFINER` and reads the key only at
  send time.

---

## Local development (optional)

```bash
npx supabase start    # local Postgres + stack
npx supabase db reset # replay migrations locally
```

Local stack is for development only; staging remains the first remote target.
