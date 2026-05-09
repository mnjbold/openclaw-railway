#!/usr/bin/env bash
# infisical-boot.sh — Pull secrets from Infisical vault at container boot
# Drop this into any Railway service as a bootstrap step.
#
# Required env vars (set in Railway):
#   INFISICAL_URL          — Infisical instance URL
#   INFISICAL_CLIENT_ID    — Machine identity Client ID  
#   INFISICAL_CLIENT_SECRET — Machine identity Client Secret
#   INFISICAL_PROJECT_ID   — Workspace/Project ID in Infisical
#   INFISICAL_ENV          — Environment slug (dev/staging/prod)
#   INFISICAL_SECRET_PATH  — Folder path for this service (e.g. /openclaw)
#
# Usage:
#   source <(bash infisical-boot.sh)        # export into current shell
#   bash infisical-boot.sh --env-file       # write to .env file
#   bash infisical-boot.sh --json           # output as JSON

set -euo pipefail

: "${INFISICAL_URL:?INFISICAL_URL not set}"
: "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID not set}"
: "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET not set}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID not set}"
: "${INFISICAL_ENV:=prod}"
: "${INFISICAL_SECRET_PATH:=/}"

LOG_PREFIX="[infisical-boot]"

log() { echo "$LOG_PREFIX $*" >&2; }

# --- Step 1: Authenticate ---
log "Authenticating with Infisical at $INFISICAL_URL ..."
AUTH_RESP=$(curl -sf --max-time 10 -X POST "$INFISICAL_URL/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\"}")

ACCESS_TOKEN=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])" 2>/dev/null)
if [ -z "$ACCESS_TOKEN" ]; then
  log "ERROR: Failed to obtain access token"
  exit 1
fi
log "Authenticated ✓"

# --- Step 2: Fetch secrets ---
log "Fetching secrets from $INFISICAL_SECRET_PATH ($INFISICAL_ENV) ..."
SECRETS_RESP=$(curl -sf --max-time 10 \
  "$INFISICAL_URL/api/v3/secrets/raw?workspaceId=$INFISICAL_PROJECT_ID&environment=$INFISICAL_ENV&secretPath=$INFISICAL_SECRET_PATH" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

SECRET_COUNT=$(echo "$SECRETS_RESP" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('secrets',[])))" 2>/dev/null)
log "Retrieved $SECRET_COUNT secrets ✓"

# --- Step 3: Output ---
MODE="${1:---export}"

case "$MODE" in
  --export)
    # Default: print export statements to stdout (use with `source <(...)`)
    echo "$SECRETS_RESP" | python3 -c "
import sys, json
secrets = json.load(sys.stdin).get('secrets', [])
for s in secrets:
    key = s['secretKey']
    val = s['secretValue'].replace(\"'\", \"'\\\"'\\\"'\")
    print(f\"export {key}='{val}'\")
"
    ;;
  --env-file)
    # Write .env file
    ENV_FILE="${INFISICAL_ENV_FILE:-.env}"
    echo "$SECRETS_RESP" | python3 -c "
import sys, json
secrets = json.load(sys.stdin).get('secrets', [])
for s in secrets:
    key = s['secretKey']
    val = s['secretValue'].replace('\"', '\\\\\"')
    print(f'{key}=\"{val}\"')
" > "$ENV_FILE"
    log "Wrote $SECRET_COUNT secrets to $ENV_FILE"
    ;;
  --json)
    echo "$SECRETS_RESP" | python3 -c "
import sys, json
secrets = json.load(sys.stdin).get('secrets', [])
result = {s['secretKey']: s['secretValue'] for s in secrets}
print(json.dumps(result, indent=2))
"
    ;;
  *)
    echo "Usage: $0 [--export|--env-file|--json]" >&2
    exit 1
    ;;
esac
