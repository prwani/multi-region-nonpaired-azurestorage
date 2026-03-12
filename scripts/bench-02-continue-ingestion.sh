#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-02-continue-ingestion.sh — Continue data generation after replication
#
# BENCHMARKING ONLY — Generates additional data after replication is active
# to measure ongoing replication latency (vs historical catchup).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

USE_AZDATAMAKER=false
DATA_SIZE_GB_EXPLICIT=false

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Continue generating data after replication is active to measure ongoing latency."
  echo "This is for benchmarking only — not part of production setup."
  echo ""
  echo "Options:"
  echo "  --data-size-gb <n>     Data to generate in this batch (default: 0.5)"
  echo "  --aci-count <n>        Number of ACI instances (default: 1, AzDataMaker only)"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  --use-azdatamaker      Use AzDataMaker via ACR/ACI with managed identity"
  echo "  --dry-run              Preview without executing"
  echo "  -h, --help             Show this help"
}

parse_bench_args() {
  local remaining=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --use-azdatamaker) USE_AZDATAMAKER=true; shift ;;
      --data-size-gb) DATA_SIZE_GB_EXPLICIT=true; remaining+=("$1" "$2"); shift 2 ;;
      *) remaining+=("$1"); shift ;;
    esac
  done
  parse_common_args "${remaining[@]}"
}

ingest_local() {
  log "Generating additional ~${DATA_SIZE_GB} GB after replication is active..."

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" EXIT

  local containers
  IFS=',' read -ra containers <<< "$(get_container_names "$SOURCE_CONTAINER_PREFIX")"
  local container_idx=0

  for i in $(seq 1 "$FILE_COUNT"); do
    local size_mb
    size_mb=$(( RANDOM % (MAX_FILE_SIZE - MIN_FILE_SIZE + 1) + MIN_FILE_SIZE ))
    local fname="continue-$(printf '%04d' "$i").bin"
    local container="${containers[$container_idx]}"
    container_idx=$(( (container_idx + 1) % ${#containers[@]} ))

    dd if=/dev/urandom of="${tmpdir}/${fname}" bs=1M count="$size_mb" 2>/dev/null

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
  local start_index
  start_index=$(get_max_aci_index)

  log "Deploying ${ACI_COUNT} additional ACI instance(s) for ongoing replication test..."
  local aci_names=()
  for x in $(seq 1 "$ACI_COUNT"); do
    local idx=$((start_index + x))
    local aci_name
    aci_name=$(get_aci_name "$idx")
    deploy_azdatamaker_instance "$aci_name" "$container_names" "50"
    aci_names+=("$aci_name")
  done

  wait_for_aci_instances_completion "${aci_names[@]}"
}

main() {
  local data_size_gb_from_env=false
  [[ -n "${DATA_SIZE_GB:-}" ]] && data_size_gb_from_env=true

  load_config
  parse_bench_args "$@"
  set_subscription

  require_tool az

  if [[ -n "${CONTINUE_SIZE_GB:-}" ]]; then
    DATA_SIZE_GB="${CONTINUE_SIZE_GB}"
  elif ! $DATA_SIZE_GB_EXPLICIT && ! $data_size_gb_from_env; then
    DATA_SIZE_GB="0.5"
  fi

  local start_time
  start_time=$(date +%s)
  compute_azdatamaker_params

  if $USE_AZDATAMAKER; then
    log "Using AzDataMaker (managed identity via ACR/ACI) for ongoing data generation..."
    ingest_azdatamaker
  else
    log "Using local file generation + az CLI upload..."
    ingest_local
  fi

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  log "Continued ingestion complete."
  ok "Elapsed: ${elapsed}s"

  # Calculate and report throughput
  if [[ "$elapsed" -gt 0 ]]; then
    local avg_file_mb throughput_mbs throughput_fps
    avg_file_mb=$(echo "scale=2; ($MAX_FILE_SIZE + $MIN_FILE_SIZE) / 2" | bc)
    throughput_mbs=$(echo "scale=2; $FILE_COUNT * $avg_file_mb / $elapsed" | bc)
    throughput_fps=$(echo "scale=2; $FILE_COUNT / $elapsed" | bc)
    ok "Throughput: ~${throughput_mbs} MB/s (~${throughput_fps} files/s)"
  fi

  ok "Additional data: ~${DATA_SIZE_GB} GB"
  log "Run bench-03-monitor-replication.sh to measure replication latency."
}

main "$@"
