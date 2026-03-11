#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 02-enable-prereqs.sh — Enable prerequisites for object replication
#
# Production-relevant: change feed, blob versioning, source containers.
# All operations are idempotent — safe to re-run.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Enable change feed, blob versioning, and create source containers."
  echo ""
  echo "Options:"
  echo "  --container-count <n>      Number of containers (default: 5)"
  echo "  --subscription <id>        Azure subscription ID"
  echo "  --dry-run                  Preview without executing"
  echo "  -h, --help                 Show this help"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription

  require_tool az
  require_tool jq

  # ── Enable change feed on source account ────────
  log "Enabling change feed on source account '${SOURCE_STORAGE}'..."
  local cf_enabled
  cf_enabled=$(az storage account blob-service-properties show \
    --account-name "$SOURCE_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "changeFeed.enabled" -o tsv 2>/dev/null || echo "false")
  if [[ "$cf_enabled" == "true" ]]; then
    ok "Change feed already enabled on '${SOURCE_STORAGE}'"
  else
    run_or_dry "az storage account blob-service-properties update \
      --account-name '${SOURCE_STORAGE}' \
      --resource-group '${RESOURCE_GROUP}' \
      --enable-change-feed true \
      --output none"
    ok "Change feed enabled on '${SOURCE_STORAGE}'"
  fi

  # ── Enable blob versioning on both accounts ─────
  for acct in "$SOURCE_STORAGE" "$DEST_STORAGE"; do
    log "Enabling blob versioning on '${acct}'..."
    local ver_enabled
    ver_enabled=$(az storage account blob-service-properties show \
      --account-name "$acct" \
      --resource-group "$RESOURCE_GROUP" \
      --query "isVersioningEnabled" -o tsv 2>/dev/null || echo "false")
    if [[ "$ver_enabled" == "true" ]]; then
      ok "Blob versioning already enabled on '${acct}'"
    else
      run_or_dry "az storage account blob-service-properties update \
        --account-name '${acct}' \
        --resource-group '${RESOURCE_GROUP}' \
        --enable-versioning true \
        --output none"
      ok "Blob versioning enabled on '${acct}'"
    fi
  done

  # ── Create source containers ────────────────────
  log "Creating ${CONTAINER_COUNT} source container(s)..."

  for i in $(seq -w 1 "$CONTAINER_COUNT"); do
    local cname="${SOURCE_CONTAINER_PREFIX}-${i}"
    local exists
    exists=$(az storage container exists \
      --name "$cname" \
      --account-name "$SOURCE_STORAGE" \
      --auth-mode login \
      --query "exists" -o tsv 2>/dev/null || echo "false")
    if [[ "$exists" == "true" ]]; then
      ok "Container '${cname}' already exists — reusing"
    else
      run_or_dry "az storage container create \
        --name '${cname}' \
        --account-name '${SOURCE_STORAGE}' \
        --auth-mode login \
        --output none"
      ok "Container '${cname}' created"
    fi
  done

  log "Prerequisites ready."
}

main "$@"
