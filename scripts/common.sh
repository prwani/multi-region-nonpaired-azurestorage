#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# common.sh — Shared functions for multi-region-nonpaired-azurestorage
#
# Source this file at the top of every script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colors ────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✔ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✖ $*${NC}"; }
dry()  { echo -e "${YELLOW}  [DRY-RUN]${NC} $*"; }

# ── Globals ───────────────────────────────────────
DRY_RUN=false
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Helpers ───────────────────────────────────────
require_tool() {
  local tool="$1"
  if ! command -v "$tool" &>/dev/null; then
    err "'$tool' is required but not installed."
    exit 1
  fi
}

run_or_dry() {
  if $DRY_RUN; then
    dry "Would run: $*"
  else
    eval "$@"
  fi
}

# ── Configuration loading ────────────────────────
load_config() {
  local config_file="${REPO_ROOT}/config.env"
  if [[ -f "$config_file" ]]; then
    # Source config.env but don't override existing env vars
    while IFS= read -r line; do
      # Skip comments and empty lines
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      # Strip inline comments (anything after # outside quotes)
      line="$(echo "$line" | sed 's/[[:space:]]*#.*//')"
      # Must contain =
      [[ "$line" != *=* ]] && continue
      local key="${line%%=*}"
      local value="${line#*=}"
      # Trim whitespace from key
      key="$(echo "$key" | tr -d '[:space:]')"
      # Trim quotes and whitespace from value
      value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\''"]//;s/["'\''"]$//')"
      [[ -z "$key" ]] && continue
      # Only set if not already defined (env var takes precedence)
      if [[ -z "${!key+x}" ]]; then
        export "$key=$value"
      fi
    done < "$config_file"
  fi

  # Apply built-in defaults for anything still unset
  : "${SOURCE_REGION:=swedencentral}"
  : "${DEST_REGION:=norwayeast}"
  : "${RESOURCE_GROUP:=rg-objrepl-demo}"
  : "${SUBSCRIPTION:=}"
  : "${CONTAINER_COUNT:=5}"
  : "${SOURCE_CONTAINER_PREFIX:=source}"
  : "${DEST_CONTAINER_PREFIX:=dest}"
  : "${REPLICATION_MODE:=default}"
  : "${DATA_SIZE_GB:=1}"
  : "${ACI_COUNT:=1}"
  : "${MAX_FILE_SIZE:=12}"
  : "${MIN_FILE_SIZE:=8}"
  : "${FILE_COUNT:=}"
  : "${ACR_NAME:=}"
  : "${ACI_PREFIX:=azdatamaker}"

  # Auto-generate names with a stable suffix derived from resource group name
  # This ensures all scripts produce the same names without needing state files
  local suffix
  suffix="$(echo -n "${RESOURCE_GROUP}" | md5sum | head -c 6)"
  : "${SOURCE_STORAGE:=objreplsrc${suffix}}"
  : "${DEST_STORAGE:=objrepldst${suffix}}"
  : "${ACR_NAME:=objreplacr${suffix}}"

  export SOURCE_REGION DEST_REGION RESOURCE_GROUP SUBSCRIPTION
  export SOURCE_STORAGE DEST_STORAGE CONTAINER_COUNT
  export SOURCE_CONTAINER_PREFIX DEST_CONTAINER_PREFIX
  export REPLICATION_MODE
  export DATA_SIZE_GB ACI_COUNT MAX_FILE_SIZE MIN_FILE_SIZE FILE_COUNT
  export ACR_NAME ACI_PREFIX
}

# ── CLI argument parsing ─────────────────────────
parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-region)       SOURCE_REGION="$2"; shift 2 ;;
      --dest-region)         DEST_REGION="$2"; shift 2 ;;
      --resource-group)      RESOURCE_GROUP="$2"; shift 2 ;;
      --subscription)        SUBSCRIPTION="$2"; shift 2 ;;
      --source-storage)      SOURCE_STORAGE="$2"; shift 2 ;;
      --dest-storage)        DEST_STORAGE="$2"; shift 2 ;;
      --container-count)     CONTAINER_COUNT="$2"; shift 2 ;;
      --replication-mode)    REPLICATION_MODE="$2"; shift 2 ;;
      --data-size-gb)        DATA_SIZE_GB="$2"; shift 2 ;;
      --aci-count)           ACI_COUNT="$2"; shift 2 ;;
      --max-file-size)       MAX_FILE_SIZE="$2"; shift 2 ;;
      --min-file-size)       MIN_FILE_SIZE="$2"; shift 2 ;;
      --file-count)          FILE_COUNT="$2"; shift 2 ;;
      --acr-name)            ACR_NAME="$2"; shift 2 ;;
      --dry-run)             DRY_RUN=true; shift ;;
      --yes|-y)              YES=true; shift ;;
      --skip-benchmark)      SKIP_BENCHMARK=true; shift ;;
      -h|--help)             usage; exit 0 ;;
      *)                     err "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done
}

# ── AzDataMaker parameter computation ────────────
compute_azdatamaker_params() {
  if [[ -n "$FILE_COUNT" ]]; then
    log "Using explicit FILE_COUNT=${FILE_COUNT} (auto-calculation skipped)"
  else
    local avg_file_size
    avg_file_size=$(echo "scale=2; ($MAX_FILE_SIZE + $MIN_FILE_SIZE) / 2" | bc)
    FILE_COUNT=$(echo "scale=0; ($DATA_SIZE_GB * 1024 + $avg_file_size - 1) / $avg_file_size" | bc)
    # Ensure at least 1 file
    [[ "$FILE_COUNT" -lt 1 ]] && FILE_COUNT=1
  fi

  local files_per_instance
  files_per_instance=$(echo "scale=0; ($FILE_COUNT + $ACI_COUNT - 1) / $ACI_COUNT" | bc)

  local est_size
  est_size=$(echo "scale=2; $FILE_COUNT * ($MAX_FILE_SIZE + $MIN_FILE_SIZE) / 2 / 1024" | bc)

  log "Data generation plan:"
  ok "Target size:       ~${est_size} GB"
  ok "Files:             ${FILE_COUNT} (${MIN_FILE_SIZE}–${MAX_FILE_SIZE} MiB each)"
  ok "ACI instances:     ${ACI_COUNT} (${files_per_instance} files each)"
  ok "Containers:        ${CONTAINER_COUNT} (round-robin)"

  export FILE_COUNT
  export FILES_PER_INSTANCE="$files_per_instance"
}

# ── Container name generation ────────────────────
get_container_names() {
  local prefix="$1"
  local count="${2:-$CONTAINER_COUNT}"
  local names=""
  for i in $(seq -w 1 "$count"); do
    [[ -n "$names" ]] && names="${names},"
    names="${names}${prefix}-${i}"
  done
  echo "$names"
}

# ── Print resolved configuration ─────────────────
print_config() {
  log "Resolved configuration:"
  echo "  ┌─────────────────────────────────────────────────"
  echo "  │ Source region:      ${SOURCE_REGION}"
  echo "  │ Dest region:        ${DEST_REGION}"
  echo "  │ Resource group:     ${RESOURCE_GROUP}"
  echo "  │ Subscription:       ${SUBSCRIPTION:-<default>}"
  echo "  │ Source storage:     ${SOURCE_STORAGE}"
  echo "  │ Dest storage:       ${DEST_STORAGE}"
  echo "  │ Containers:         ${CONTAINER_COUNT} (${SOURCE_CONTAINER_PREFIX}-NN → ${DEST_CONTAINER_PREFIX}-NN)"
  echo "  │ Replication mode:   ${REPLICATION_MODE}"
  echo "  │ Data size:          ${DATA_SIZE_GB} GB"
  echo "  │ ACI count:          ${ACI_COUNT}"
  echo "  │ ACR name:           ${ACR_NAME}"
  echo "  └─────────────────────────────────────────────────"
}

# ── Subscription helper ──────────────────────────
set_subscription() {
  if [[ -n "$SUBSCRIPTION" ]]; then
    log "Setting subscription to ${SUBSCRIPTION}"
    run_or_dry "az account set --subscription '${SUBSCRIPTION}'"
  fi
}
