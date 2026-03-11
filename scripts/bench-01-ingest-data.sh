#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-01-ingest-data.sh — Generate test data and upload to source containers
#
# BENCHMARKING ONLY — generates test data to measure replication performance.
#
# Uses local file generation + az CLI upload (--auth-mode login) by default.
# Pass --use-azdatamaker to use AzDataMaker via ACR/ACI instead (requires
# shared key access on the storage account).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

USE_AZDATAMAKER=false

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Generate test data and upload to source containers."
  echo "This is for benchmarking only — not part of production setup."
  echo ""
  echo "Options:"
  echo "  --data-size-gb <n>     Total data to generate in GB (default: 1)"
  echo "  --aci-count <n>        Number of ACI instances (default: 1, AzDataMaker only)"
  echo "  --container-count <n>  Number of containers (default: 5)"
  echo "  --use-azdatamaker      Use AzDataMaker via ACR/ACI (needs shared key access)"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  --dry-run              Preview without executing"
  echo "  -h, --help             Show this help"
}

# Override parse to handle --use-azdatamaker
parse_bench_args() {
  local remaining=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --use-azdatamaker) USE_AZDATAMAKER=true; shift ;;
      *) remaining+=("$1"); shift ;;
    esac
  done
  parse_common_args "${remaining[@]}"
}

ingest_local() {
  compute_azdatamaker_params

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" EXIT

  log "Generating ${FILE_COUNT} test files locally..."
  local containers
  IFS=',' read -ra containers <<< "$(get_container_names "$SOURCE_CONTAINER_PREFIX")"
  local container_idx=0

  for i in $(seq 1 "$FILE_COUNT"); do
    # Random size between MIN and MAX
    local size_mb
    size_mb=$(( RANDOM % (MAX_FILE_SIZE - MIN_FILE_SIZE + 1) + MIN_FILE_SIZE ))
    local fname="testfile-$(printf '%04d' "$i").bin"
    local container="${containers[$container_idx]}"
    container_idx=$(( (container_idx + 1) % ${#containers[@]} ))

    # Generate file
    dd if=/dev/urandom of="${tmpdir}/${fname}" bs=1M count="$size_mb" 2>/dev/null

    # Upload
    run_or_dry "az storage blob upload \
      --account-name '${SOURCE_STORAGE}' \
      --container-name '${container}' \
      --name '${fname}' \
      --file '${tmpdir}/${fname}' \
      --auth-mode login \
      --overwrite \
      --no-progress \
      --output none"

    rm -f "${tmpdir}/${fname}"

    if (( i % 10 == 0 )); then
      ok "${i}/${FILE_COUNT} files uploaded"
    fi
  done
  ok "All ${FILE_COUNT} files uploaded"
}

ingest_azdatamaker() {
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

  compute_azdatamaker_params

  # ── Enable shared key access (required by AzDataMaker connection string) ──
  log "Ensuring shared key access is enabled on source account..."
  run_or_dry "az storage account update \
    --name '${SOURCE_STORAGE}' \
    --resource-group '${RESOURCE_GROUP}' \
    --allow-shared-key-access true \
    --output none"
  warn "If shared key access is blocked by subscription policy, use default mode (without --use-azdatamaker)"

  # ── Get credentials ─────────────────────────────
  local acr_server acr_user acr_pwd storage_cs
  acr_server=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)
  acr_user=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
  acr_pwd=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)
  storage_cs=$(az storage account show-connection-string --name "$SOURCE_STORAGE" --resource-group "$RESOURCE_GROUP" -o tsv)

  local container_names
  container_names=$(get_container_names "$SOURCE_CONTAINER_PREFIX")

  # ── Deploy ACI instances ────────────────────────
  log "Deploying ${ACI_COUNT} ACI instance(s)..."
  for x in $(seq 1 "$ACI_COUNT"); do
    local aci_name
    aci_name=$(printf "%s-%02d" "$ACI_PREFIX" "$x")

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
}

main() {
  load_config
  parse_bench_args "$@"
  set_subscription

  require_tool az

  local start_time
  start_time=$(date +%s)

  if $USE_AZDATAMAKER; then
    log "Using AzDataMaker (ACR/ACI) for data generation..."
    ingest_azdatamaker
  else
    log "Using local file generation + az CLI upload..."
    ingest_local
  fi

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  log "Data ingestion complete."
  ok "Elapsed time: ${elapsed}s"
  ok "Target data: ~${DATA_SIZE_GB} GB across ${CONTAINER_COUNT} container(s)"
}

main "$@"
