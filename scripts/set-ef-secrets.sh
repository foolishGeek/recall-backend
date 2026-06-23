#!/usr/bin/env bash
# Set all Edge Function secrets on the currently linked Supabase project.
# Usage: copy .env.example to .env, fill values, then: ./scripts/set-ef-secrets.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Missing .env — copy from .env.example and fill values."
  exit 1
fi

# shellcheck disable=SC1091
source .env

SUPABASE="npx --yes supabase@latest"

required=(
  GEMINI_API_KEY
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  REVENUECAT_WEBHOOK_SECRET
  REVENUECAT_REST_API_KEY
  FCM_SERVICE_ACCOUNT_JSON
  CRON_SECRET
)

for key in "${required[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "Missing $key in .env"
    exit 1
  fi
done

$SUPABASE secrets set \
  GEMINI_API_KEY="$GEMINI_API_KEY" \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  OPENAI_API_KEY="$OPENAI_API_KEY" \
  REVENUECAT_WEBHOOK_SECRET="$REVENUECAT_WEBHOOK_SECRET" \
  REVENUECAT_REST_API_KEY="$REVENUECAT_REST_API_KEY" \
  FCM_SERVICE_ACCOUNT_JSON="$FCM_SERVICE_ACCOUNT_JSON" \
  CRON_SECRET="$CRON_SECRET"

echo "Secrets set on linked project."
