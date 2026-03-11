#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-01-ingest-data.sh — Generate test data using AzDataMaker
#
# BENCHMARKING ONLY — ACR, ACI, and AzDataMaker are not part of a production
# object replication setup. This script creates test data to measure
# replication performance.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Deploy AzDataMaker via ACR/ACI to generate test data in source containers."
  echo "This is for benchmarking only — not part of production setup."
  echo ""
  echo "Options:"
  echo "  --data-size-gb <n>     Total data to generate in GB (default: 1)"
  echo "  --aci-count <n>        Number of ACI instances (default: 1)"
  echo "  --container-count <n>  Number of containers (default: 5)"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  --dry-run              Preview without executing"
  echo "  -h, --help             Show this help"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription

  require_tool az

  local start_time
  start_time=$(date +%s)

  # ── Create ACR ──────────────────────────────────
  log "Setting up Azure Container Registry '${ACR_NAME}'..."
  if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    ok "ACR '${ACR_NAME}' already exists — reusing"
  else
    run_or_dry "az acr create \
      --name '${ACR_NAME}' \
      --resource-group '${RESOURCE_GROUP}' \
      --admin-enabled true \
      --sku Standard \
      --location '${SOURCE_REGION}' \
      --output none"
    ok "ACR '${ACR_NAME}' created"
  fi

  # ── Build AzDataMaker image ─────────────────────
  log "Building AzDataMaker container image..."
  run_or_dry "az acr build \
    --resource-group '${RESOURCE_GROUP}' \
    --registry '${ACR_NAME}' \
    https://github.com/Azure/azdatamaker.git \
    -f src/AzDataMaker/AzDataMaker/Dockerfile \
    --image azdatamaker:latest \
    --no-logs \
    --output none" || true
  ok "AzDataMaker image built"

  # ── Compute data generation parameters ──────────
  compute_azdatamaker_params

  # ── Enable shared key access (required by AzDataMaker connection string) ──
  log "Ensuring shared key access is enabled on source account..."
  run_or_dry "az storage account update \
    --name '${SOURCE_STORAGE}' \
    --resource-group '${RESOURCE_GROUP}' \
    --allow-shared-key-access true \
    --output none"
  ok "Shared key access enabled on '${SOURCE_STORAGE}'"

  # ── Get credentials ─────────────────────────────
  local acr_server acr_user acr_pwd storage_cs
  acr_server=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)
  acr_user=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
  acr_pwd=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)
  storage_cs=$(az storage account show-connection-string --name "$SOURCE_STORAGE" --resource-group "$RESOURCE_GROUP" -o tsv)

  # ── Build container list ────────────────────────
  local container_names
  container_names=$(get_container_names "$SOURCE_CONTAINER_PREFIX")

  # ── Deploy ACI instances ────────────────────────
  log "Deploying ${ACI_COUNT} ACI instance(s)..."
  for x in $(seq 1 "$ACI_COUNT"); do
    local aci_name
    aci_name=$(printf "%s-%02d" "$ACI_PREFIX" "$x")

    # Check if instance already exists
    if az container show --name "$aci_name" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
      ok "ACI '${aci_name}' already exists — skipping"
      continue
    fi

    run_or_dry "az container create \
      --name '${aci_name}' \
      --resource-group '${RESOURCE_GROUP}' \
      --location '${SOURCE_REGION}' \
      --os-type Linux \
      --cpu 1 \
      --memory 1 \
      --registry-login-server '${acr_server}' \
      --registry-username '${acr_user}' \
      --registry-password '${acr_pwd}' \
      --image '${acr_server}/azdatamaker:latest' \
      --restart-policy Never \
      --no-wait \
      --environment-variables \
        FileCount='${FILES_PER_INSTANCE}' \
        MaxFileSize='${MAX_FILE_SIZE}' \
        MinFileSize='${MIN_FILE_SIZE}' \
        ReportStatusIncrement='100' \
        BlobContainers='${container_names}' \
        RandomFileContents='false' \
      --secure-environment-variables \
        ConnectionStrings__MyStorageConnection='${storage_cs}' \
      --output none"
    ok "ACI '${aci_name}' deployed"
  done

  # ── Wait for completion ─────────────────────────
  if ! $DRY_RUN; then
    log "Waiting for ACI instances to complete..."
    local all_done=false
    while ! $all_done; do
      all_done=true
      for x in $(seq 1 "$ACI_COUNT"); do
        local aci_name
        aci_name=$(printf "%s-%02d" "$ACI_PREFIX" "$x")
        local state
        state=$(az container show \
          --name "$aci_name" \
          --resource-group "$RESOURCE_GROUP" \
          --query "instanceView.state" -o tsv 2>/dev/null || echo "Unknown")
        if [[ "$state" != "Succeeded" && "$state" != "Failed" && "$state" != "Terminated" ]]; then
          all_done=false
        fi
      done
      if ! $all_done; then
        echo -n "."
        sleep 15
      fi
    done
    echo ""
  fi

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  log "Data ingestion complete."
  ok "Elapsed time: ${elapsed}s"
  ok "Target data: ~${DATA_SIZE_GB} GB across ${CONTAINER_COUNT} container(s)"
}

main "$@"
