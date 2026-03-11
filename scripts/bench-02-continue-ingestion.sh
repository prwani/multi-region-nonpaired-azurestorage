#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-02-continue-ingestion.sh — Continue data generation after replication
#
# BENCHMARKING ONLY — Generates additional data after replication is active
# to measure ongoing replication latency (vs historical catchup).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Continue generating data after replication is active to measure ongoing latency."
  echo "This is for benchmarking only — not part of production setup."
  echo ""
  echo "Options:"
  echo "  --data-size-gb <n>     Data to generate in this batch (default: 0.5)"
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
  : "${DATA_SIZE_GB:=0.5}"

  local start_time
  start_time=$(date +%s)

  compute_azdatamaker_params

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

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  log "Continued ingestion complete."
  ok "Elapsed: ${elapsed}s"
  ok "Additional data: ~${DATA_SIZE_GB} GB"
  log "Run bench-03-monitor-replication.sh to measure replication latency."
}

main "$@"
