#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cleanup.sh — Teardown all resources created by this demo
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

YES="${YES:-false}"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Delete all resources created by the object replication demo."
  echo ""
  echo "Options:"
  echo "  --yes, -y              Skip confirmation prompt"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  --dry-run              Preview without executing"
  echo "  -h, --help             Show this help"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription
  print_config

  require_tool az

  # ── Confirmation ────────────────────────────────
  if ! $YES && ! $DRY_RUN; then
    echo ""
    warn "This will DELETE the following resources:"
    echo "  • Resource group:    ${RESOURCE_GROUP}"
    echo "  • Storage accounts:  ${SOURCE_STORAGE}, ${DEST_STORAGE}"
    echo "  • ACR:               ${ACR_NAME}"
    echo "  • ACI instances:     ${ACI_PREFIX}-*"
    echo ""
    read -rp "Are you sure? (y/N): " confirm
    if [[ "$confirm" != [yY] ]]; then
      log "Aborted."
      exit 0
    fi
  fi

  # ── Delete replication policy ───────────────────
  log "Removing replication policies..."
  local policies
  policies=$(az storage account or-policy list \
    --account-name "$DEST_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[].policyId" -o tsv 2>/dev/null || echo "")
  for pid in $policies; do
    run_or_dry "az storage account or-policy delete \
      --account-name '${DEST_STORAGE}' \
      --resource-group '${RESOURCE_GROUP}' \
      --policy-id '${pid}' \
      --output none" || true
    run_or_dry "az storage account or-policy delete \
      --account-name '${SOURCE_STORAGE}' \
      --resource-group '${RESOURCE_GROUP}' \
      --policy-id '${pid}' \
      --output none" || true
    ok "Deleted policy ${pid}"
  done

  # ── Delete ACI instances ────────────────────────
  log "Deleting ACI instances..."
  local instances
  instances=$(az container list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?starts_with(name, '${ACI_PREFIX}-')].name" -o tsv 2>/dev/null || echo "")
  for inst in $instances; do
    run_or_dry "az container delete \
      --name '${inst}' \
      --resource-group '${RESOURCE_GROUP}' \
      --yes \
      --output none" || true
    ok "Deleted ACI: ${inst}"
  done
  [[ -z "$instances" ]] && ok "No ACI instances found"

  # ── Delete ACR ──────────────────────────────────
  log "Deleting container registry '${ACR_NAME}'..."
  if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    run_or_dry "az acr delete \
      --name '${ACR_NAME}' \
      --resource-group '${RESOURCE_GROUP}' \
      --yes \
      --output none"
    ok "ACR '${ACR_NAME}' deleted"
  else
    ok "ACR '${ACR_NAME}' not found — skipping"
  fi

  # ── Delete resource group (includes storage accounts) ──
  log "Deleting resource group '${RESOURCE_GROUP}'..."
  if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    run_or_dry "az group delete \
      --name '${RESOURCE_GROUP}' \
      --yes \
      --no-wait \
      --output none"
    ok "Resource group '${RESOURCE_GROUP}' deletion initiated (--no-wait)"
  else
    ok "Resource group '${RESOURCE_GROUP}' not found — skipping"
  fi

  log "Cleanup complete."
}

main "$@"
