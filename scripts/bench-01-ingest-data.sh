#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-01-ingest-data.sh — Generate test data and upload to source containers
#
# BENCHMARKING ONLY — generates test data to measure replication performance.
#
# Uses local file generation + az CLI upload (--auth-mode login) by default.
# Pass --use-azdatamaker to use AzDataMaker via ACR/ACI with managed identity
# instead.
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
  echo "  --use-azdatamaker      Use AzDataMaker via ACR/ACI with managed identity"
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
  initialize_azdatamaker_infra

  local container_names
  container_names=$(get_container_names "$SOURCE_CONTAINER_PREFIX")

  # ── Deploy ACI instances ────────────────────────
  log "Deploying ${ACI_COUNT} ACI instance(s)..."
  local aci_names=()
  for x in $(seq 1 "$ACI_COUNT"); do
    local aci_name
    aci_name=$(get_aci_name "$x")

    deploy_azdatamaker_instance "$aci_name" "$container_names" "100" "true"
    aci_names+=("$aci_name")
  done

  wait_for_aci_instances_completion "${aci_names[@]}"
}

main() {
  load_config
  parse_bench_args "$@"
  set_subscription

  require_tool az

  local start_time
  start_time=$(date +%s)
  compute_azdatamaker_params

  if $USE_AZDATAMAKER; then
    log "Using AzDataMaker (managed identity via ACR/ACI) for data generation..."
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
