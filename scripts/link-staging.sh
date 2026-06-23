#!/usr/bin/env bash
# Finish Supabase staging CLI link after you have credentials.
#
# Required (NOT the sb_publishable / sb_secret project keys):
#   1. Personal access token: https://supabase.com/dashboard/account/tokens  (sbp_...)
#   2. Database password: project Settings → Database (set at project creation)
#
# Usage:
#   export SUPABASE_ACCESS_TOKEN='sbp_...'
#   export SUPABASE_DB_PASSWORD='your-db-password'
#   ./scripts/link-staging.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REF="vxbqzzebiuxzywmekdex"
SUPABASE="npx --yes supabase@latest"

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  echo "Set SUPABASE_ACCESS_TOKEN (sbp_... from Account Tokens, NOT sb_secret_)."
  exit 1
fi

if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  echo "Set SUPABASE_DB_PASSWORD (project database password)."
  exit 1
fi

echo "==> Linking staging ($REF)..."
$SUPABASE link --project-ref "$REF" --password "$SUPABASE_DB_PASSWORD" --yes

echo "==> Enabling extensions..."
$SUPABASE db query --linked -f scripts/sql/enable-extensions.sql

echo "==> Setting CRON_SECRET..."
$SUPABASE secrets set "CRON_SECRET=$(cat secrets/cron-staging.txt)"

echo "==> Staging linked. Configure Auth in dashboard (see docs/SETUP-RUNBOOK.md §2)."
echo "    Fill remaining secrets in .env and run ./scripts/set-ef-secrets.sh when ready."
