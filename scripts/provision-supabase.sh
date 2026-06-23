#!/usr/bin/env bash
# Recall S00 — post-login Supabase provisioning helper.
# Prereq: npx supabase login (or SUPABASE_ACCESS_TOKEN set)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SUPABASE="npx --yes supabase@latest"

echo "==> Checking Supabase CLI auth..."
if ! $SUPABASE projects list &>/dev/null; then
  echo "Not logged in. Run: npx supabase login"
  echo "Or export SUPABASE_ACCESS_TOKEN from https://supabase.com/dashboard/account/tokens"
  exit 1
fi

echo "==> Existing projects:"
$SUPABASE projects list

echo ""
echo "Create projects in dashboard if missing:"
echo "  - recall-staging (note project ref)"
echo "  - recall-prod"
echo ""
read -r -p "Staging project ref: " STAGING_REF
read -r -p "Prod project ref (optional, Enter to skip): " PROD_REF

echo "==> Linking CLI to staging ($STAGING_REF)..."
$SUPABASE link --project-ref "$STAGING_REF"

echo "==> Enable extensions (paste scripts/sql/enable-extensions.sql in SQL Editor for both projects)"
echo "==> Set Edge Function secrets (see .env.example). Example:"
echo "  $SUPABASE secrets set CRON_SECRET=\$(cat secrets/cron-staging.txt)"

if [[ -n "${PROD_REF}" ]]; then
  echo ""
  echo "To push to prod later:"
  echo "  $SUPABASE link --project-ref $PROD_REF"
  echo "  $SUPABASE db push"
fi

echo "Done. Fill secrets/LOCAL-SECRETS.md and docs/PREFLIGHT-CHECKLIST.md."
