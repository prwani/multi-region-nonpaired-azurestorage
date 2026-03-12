#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bench-03-monitor-replication.sh — Monitor replication status and latency
#
# BENCHMARKING ONLY — Uses Azure Monitor metrics and blob replication status
# headers to measure historical catchup and ongoing replication performance.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Monitor object replication metrics and blob-level replication status."
  echo "This is for benchmarking only."
  echo ""
  echo "Options:"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  --dry-run              Preview without executing"
  echo "  -h, --help             Show this help"
}

check_blob_replication_status() {
  local account="$1"
  local container="$2"
  local sample_count="${3:-5}"

  log "Checking replication status for blobs in '${container}'..."
  local blobs
  blobs=$(az storage blob list \
    --account-name "$account" \
    --auth-mode login \
    --container-name "$container" \
    --num-results "$sample_count" \
    --query "[].name" -o tsv 2>/dev/null || echo "")

  if [[ -z "$blobs" ]]; then
    warn "No blobs found in '${container}'"
    return
  fi

  local total=0 completed=0 pending=0 failed=0
  while IFS= read -r blob; do
    [[ -z "$blob" ]] && continue
    total=$((total + 1))
    local status
    status=$(az storage blob show \
      --account-name "$account" \
      --auth-mode login \
      --container-name "$container" \
      --name "$blob" \
      --query "properties.replicationStatus" -o tsv 2>/dev/null || echo "unknown")
    case "$status" in
      complete) completed=$((completed + 1)) ;;
      pending)  pending=$((pending + 1)) ;;
      failed)   failed=$((failed + 1)) ;;
    esac
  done <<< "$blobs"

  echo "  ┌─────────────────────────────────────"
  echo "  │ Container: ${container}"
  echo "  │ Sampled:   ${total} blobs"
  echo "  │ Completed: ${completed}"
  echo "  │ Pending:   ${pending}"
  echo "  │ Failed:    ${failed}"
  echo "  └─────────────────────────────────────"
}

query_replication_metrics() {
  local account_id="$1"
  local metric="$2"
  local display_name="$3"

  local end_time start_time
  end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_time=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
               date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  if [[ -z "$start_time" ]]; then
    warn "Could not compute start time — skipping metric ${display_name}"
    return
  fi

  local result
  result=$(az monitor metrics list \
    --resource "$account_id" \
    --metric "$metric" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --interval PT5M \
    --aggregation Total \
    --query "value[0].timeseries[0].data[-1].total" \
    -o tsv 2>/dev/null || echo "N/A")

  echo "  │ ${display_name}: ${result}"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription

  require_tool az
  require_tool jq

  # ── Get account info ────────────────────────────
  local src_id
  src_id=$(az storage account show \
    --name "$SOURCE_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "id" -o tsv)

  # ── Check blob-level replication status ─────────
  log "═══ Blob Replication Status (sampled) ═══"
  for i in $(seq 1 "$CONTAINER_COUNT"); do
    local cname
    cname=$(get_default_container_name "$SOURCE_CONTAINER_PREFIX" "$i" "$CONTAINER_COUNT")
    check_blob_replication_status "$SOURCE_STORAGE" "$cname" 5
  done

  # ── Query Azure Monitor metrics ─────────────────
  log "═══ Azure Monitor Replication Metrics (last hour) ═══"
  echo "  ┌─────────────────────────────────────"
  query_replication_metrics "$src_id" "ObjectReplicationSourceBytesReplicated" "Bytes replicated"
  query_replication_metrics "$src_id" "ObjectReplicationSourceOperationsReplicated" "Operations replicated"
  echo "  └─────────────────────────────────────"

  # ── Summary ─────────────────────────────────────
  log "═══ Summary ═══"
  ok "Source account:  ${SOURCE_STORAGE} (${SOURCE_REGION})"
  ok "Dest account:    ${DEST_STORAGE} (${DEST_REGION})"
  ok "Replication mode: ${REPLICATION_MODE}"
  ok "Containers:      ${CONTAINER_COUNT}"
  echo ""
  log "For detailed metrics, visit Azure Portal → Storage Account → Monitoring → Metrics"
  log "Key metrics to track:"
  echo "  • ObjectReplicationSourceBytesReplicated"
  echo "  • ObjectReplicationSourceOperationsReplicated"
  if [[ "$REPLICATION_MODE" == "priority" ]]; then
    echo "  • Operations pending for replication (by time bucket)"
    echo "  • Bytes pending for replication (by time bucket)"
  fi
}

main "$@"
