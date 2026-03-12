#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-all.sh — 1-command orchestrator
#
# Runs core setup and (optionally) benchmarking scripts sequentially.
# Use --skip-benchmark to run only the production-relevant core setup.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SKIP_BENCHMARK="${SKIP_BENCHMARK:-false}"
USE_AZDATAMAKER=false

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Run all setup steps in sequence. Supports all config.env overrides."
  echo ""
  echo "Options:"
  echo "  --skip-benchmark       Run only core setup (no benchmark data generation)"
  echo "  --use-azdatamaker      Use optional AzDataMaker benchmarking path"
  echo "  --dry-run              Preview without executing"
  echo "  --subscription <id>    Azure subscription ID"
  echo "  -h, --help             Show this help"
  echo ""
  echo "All config.env parameters can be overridden via CLI flags."
  echo "Example: $0 --data-size-gb 10 --source-region eastus --dry-run"
}

run_step() {
  local script="$1"
  local description="$2"
  local step_start step_end step_elapsed

  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "${description}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  step_start=$(date +%s)
  bash "${SCRIPT_DIR}/${script}" "$@"
  step_end=$(date +%s)
  step_elapsed=$((step_end - step_start))

  ok "${description} — completed in ${step_elapsed}s"
  STEP_TIMES+=("${description}: ${step_elapsed}s")
}

parse_setup_args() {
  local remaining=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --use-azdatamaker) USE_AZDATAMAKER=true; shift ;;
      *) remaining+=("$1"); shift ;;
    esac
  done
  parse_common_args "${remaining[@]}"
}

main() {
  load_config
  parse_setup_args "$@"
  print_config

  local total_start
  total_start=$(date +%s)
  STEP_TIMES=()

  # ── Forward args to sub-scripts ─────────────────
  local fwd_args=()
  [[ -n "$SUBSCRIPTION" ]] && fwd_args+=(--subscription "$SUBSCRIPTION")
  $DRY_RUN && fwd_args+=(--dry-run)
  local bench_fwd_args=("${fwd_args[@]}")
  $USE_AZDATAMAKER && bench_fwd_args+=(--use-azdatamaker)

  # ── Core setup (production-relevant) ────────────
  log "══════ CORE SETUP ══════"
  run_step "01-create-storage.sh" "Step 1: Create storage accounts" "${fwd_args[@]}"
  run_step "02-enable-prereqs.sh" "Step 2: Enable prerequisites" "${fwd_args[@]}"

  if ! $SKIP_BENCHMARK; then
    # ── Benchmarking ──────────────────────────────
    log ""
    log "══════ BENCHMARKING (data ingestion before replication) ══════"
    run_step "bench-01-ingest-data.sh" "Bench 1: Ingest test data" "${bench_fwd_args[@]}"
  fi

  # Replication setup comes after initial data ingestion
  run_step "03-setup-replication.sh" "Step 3: Setup object replication" "${fwd_args[@]}"

  if ! $SKIP_BENCHMARK; then
    run_step "bench-02-continue-ingestion.sh" "Bench 2: Continue ingestion" "${bench_fwd_args[@]}"
    run_step "bench-03-monitor-replication.sh" "Bench 3: Monitor replication" "${fwd_args[@]}"
  fi

  # ── Summary ─────────────────────────────────────
  local total_end total_elapsed
  total_end=$(date +%s)
  total_elapsed=$((total_end - total_start))

  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "ALL STEPS COMPLETE"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for t in "${STEP_TIMES[@]}"; do
    echo "  • ${t}"
  done
  echo "  ────────────────────────────"
  ok "Total elapsed: ${total_elapsed}s"
  echo ""
  log "To clean up: ./scripts/cleanup.sh"
}

main "$@"
