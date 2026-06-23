#!/usr/bin/env bash
# Link and bootstrap Supabase prod (Recall-Prod).
#
# Required:
#   SUPABASE_ACCESS_TOKEN (sbp_...)
#   SUPABASE_DB_PASSWORD (prod database password from project creation)
#
# Usage:
#   export SUPABASE_ACCESS_TOKEN='sbp_...'
#   export SUPABASE_DB_PASSWORD='prod-db-password'
#   ./scripts/link-prod.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REF="cpyhkjourabizancgkjm"
SUPABASE="npx --yes supabase@latest"

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  echo "Set SUPABASE_ACCESS_TOKEN (sbp_...)."
  exit 1
fi

if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  echo "Set SUPABASE_DB_PASSWORD (Recall-Prod database password)."
  exit 1
fi

echo "==> Linking prod ($REF)..."
$SUPABASE link --project-ref "$REF" --password "$SUPABASE_DB_PASSWORD" --yes

echo "==> Enabling extensions..."
$SUPABASE db query --linked -f scripts/sql/enable-extensions.sql

echo "==> Setting CRON_SECRET..."
$SUPABASE secrets set "CRON_SECRET=$(cat secrets/cron-prod.txt)"

echo "==> Prod linked. Configure Auth (site_url app.recall://login-callback)."
echo "    Re-link staging for daily work: npx supabase link --project-ref vxbqzzebiuxzywmekdex"
