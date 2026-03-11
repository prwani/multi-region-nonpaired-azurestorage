#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 01-create-storage.sh — Create resource group and source/destination storage accounts
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Create resource group and storage accounts for object replication demo."
  echo ""
  echo "Options:"
  echo "  --source-region <region>   Source region (default: swedencentral)"
  echo "  --dest-region <region>     Destination region (default: norwayeast)"
  echo "  --resource-group <name>    Resource group name"
  echo "  --subscription <id>        Azure subscription ID"
  echo "  --dry-run                  Preview without executing"
  echo "  -h, --help                 Show this help"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription
  print_config

  require_tool az

  # ── Resource Group ──────────────────────────────
  log "Creating resource group '${RESOURCE_GROUP}' in ${SOURCE_REGION}..."
  if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    ok "Resource group '${RESOURCE_GROUP}' already exists — reusing"
  else
    run_or_dry "az group create \
      --name '${RESOURCE_GROUP}' \
      --location '${SOURCE_REGION}' \
      --output none"
    ok "Resource group '${RESOURCE_GROUP}' created"
  fi

  # ── Source Storage Account ──────────────────────
  log "Creating source storage account '${SOURCE_STORAGE}' in ${SOURCE_REGION}..."
  if az storage account show --name "$SOURCE_STORAGE" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    ok "Source storage account '${SOURCE_STORAGE}' already exists — reusing"
  else
    run_or_dry "az storage account create \
      --name '${SOURCE_STORAGE}' \
      --resource-group '${RESOURCE_GROUP}' \
      --location '${SOURCE_REGION}' \
      --kind StorageV2 \
      --sku Standard_LRS \
      --access-tier Hot \
      --https-only true \
      --output none"
    ok "Source storage account '${SOURCE_STORAGE}' created"
  fi

  # ── Destination Storage Account ─────────────────
  log "Creating destination storage account '${DEST_STORAGE}' in ${DEST_REGION}..."
  if az storage account show --name "$DEST_STORAGE" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    ok "Destination storage account '${DEST_STORAGE}' already exists — reusing"
  else
    run_or_dry "az storage account create \
      --name '${DEST_STORAGE}' \
      --resource-group '${RESOURCE_GROUP}' \
      --location '${DEST_REGION}' \
      --kind StorageV2 \
      --sku Standard_LRS \
      --access-tier Hot \
      --https-only true \
      --output none"
    ok "Destination storage account '${DEST_STORAGE}' created"
  fi

  log "Storage accounts ready."
}

main "$@"
