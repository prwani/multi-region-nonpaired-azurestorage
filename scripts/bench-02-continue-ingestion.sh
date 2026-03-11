#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-02-continue-ingestion.sh — Continue data generation after replication
#
# BENCHMARKING ONLY — Generates additional data after replication is active
# to measure ongoing replication latency (vs historical catchup).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONTINUE_SIZE_GB="${CONTINUE_SIZE_GB:-0.5}"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Continue AzDataMaker after replication is active to measure ongoing latency."
  echo "This is for benchmarking only — not part of production setup."
  echo ""
  echo "Options:"
  echo "  --data-size-gb <n>     Data to generate in this batch (default: 0.5)"
  echo "  --aci-count <n>        Number of ACI instances (default: 1)"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  --dry-run              Preview without executing"
  echo "  -h, --help             Show this help"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription

  require_tool az

  # Use a smaller default for continuation
  DATA_SIZE_GB="${CONTINUE_SIZE_GB}"

  local start_time
  start_time=$(date +%s)

  compute_azdatamaker_params

  # ── Get credentials ─────────────────────────────
  local acr_server acr_user acr_pwd storage_cs
  acr_server=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)
  acr_user=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
  acr_pwd=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)
  storage_cs=$(az storage account show-connection-string --name "$SOURCE_STORAGE" --resource-group "$RESOURCE_GROUP" -o tsv)

  local container_names
  container_names=$(get_container_names "$SOURCE_CONTAINER_PREFIX")

  # ── Find next ACI index ─────────────────────────
  local max_idx
  max_idx=$(az container list \
    --resource-group "$RESOURCE_GROUP" \
    --query "length([?starts_with(name, '${ACI_PREFIX}-')])" -o tsv 2>/dev/null || echo "0")

  log "Deploying ${ACI_COUNT} additional ACI instance(s) for ongoing replication test..."
  for x in $(seq 1 "$ACI_COUNT"); do
    local idx=$((max_idx + x))
    local aci_name
    aci_name=$(printf "%s-%02d" "$ACI_PREFIX" "$idx")

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
        ReportStatusIncrement='50' \
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
        local idx=$((max_idx + x))
        local aci_name
        aci_name=$(printf "%s-%02d" "$ACI_PREFIX" "$idx")
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

  log "Continued ingestion complete."
  ok "Elapsed: ${elapsed}s"
  ok "Additional data: ~${DATA_SIZE_GB} GB"
  log "Run bench-03-monitor-replication.sh to measure replication latency."
}

main "$@"
