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
AZDATAMAKER_GIT_URL="${AZDATAMAKER_GIT_URL:-https://github.com/Azure/AzDataMaker.git}"
AZDATAMAKER_DOCKERFILE="${AZDATAMAKER_DOCKERFILE:-src/AzDataMaker/AzDataMaker/Dockerfile}"
AZDATAMAKER_IMAGE="${AZDATAMAKER_IMAGE:-azdatamaker:latest}"
STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE="${STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE:-Storage Blob Data Contributor}"

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
  ok "ACI instances:     ${ACI_COUNT} (${files_per_instance} files each, AzDataMaker only)"
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

get_aci_name() {
  local index="$1"
  printf "%s-%02d" "$ACI_PREFIX" "$index"
}

wait_for_aci_principal_id() {
  local aci_name="$1"

  if $DRY_RUN; then
    echo "<dry-run-principal-id>"
    return 0
  fi

  local principal_id=""
  for _ in $(seq 1 60); do
    principal_id=$(az container show \
      --name "$aci_name" \
      --resource-group "$RESOURCE_GROUP" \
      --query "identity.principalId" -o tsv 2>/dev/null || echo "")
    if [[ -n "$principal_id" ]]; then
      echo "$principal_id"
      return 0
    fi
    sleep 5
  done

  err "Managed identity principalId for ACI '${aci_name}' was not available in time"
  return 1
}

wait_for_aci_deleted() {
  local aci_name="$1"

  $DRY_RUN && return 0

  for _ in $(seq 1 60); do
    if ! az container show \
      --name "$aci_name" \
      --resource-group "$RESOURCE_GROUP" \
      --query "id" -o tsv &>/dev/null; then
      return 0
    fi
    sleep 5
  done

  err "Timed out waiting for ACI '${aci_name}' to delete"
  return 1
}

aci_uses_managed_identity_storage_uri() {
  local aci_name="$1"

  local principal_id storage_uri
  principal_id=$(az container show \
    --name "$aci_name" \
    --resource-group "$RESOURCE_GROUP" \
    --query "identity.principalId" -o tsv 2>/dev/null || echo "")
  storage_uri=$(az container show \
    --name "$aci_name" \
    --resource-group "$RESOURCE_GROUP" \
    --query "containers[0].environmentVariables[?name=='StorageAccountUri'].value | [0]" -o tsv 2>/dev/null || echo "")

  [[ -n "$principal_id" && -n "$storage_uri" ]]
}

ensure_storage_blob_data_contributor() {
  local principal_id="$1"
  local storage_account_id="$2"
  local aci_name="${3:-managed-identity}"

  if $DRY_RUN; then
    dry "Would assign '${STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE}' to '${aci_name}' (${principal_id}) on '${storage_account_id}'"
    return 0
  fi

  local existing_count
  existing_count=$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --scope "$storage_account_id" \
    --query "[?roleDefinitionName=='${STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE}'] | length(@)" -o tsv 2>/dev/null || echo "0")

  if [[ "${existing_count:-0}" -ge 1 ]]; then
    ok "ACI '${aci_name}' already has '${STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE}'"
    return 0
  fi

  local attempt
  for attempt in $(seq 1 12); do
    if az role assignment create \
      --assignee-object-id "$principal_id" \
      --assignee-principal-type ServicePrincipal \
      --role "$STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE" \
      --scope "$storage_account_id" \
      --output none &>/dev/null; then
      ok "Granted '${STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE}' to ACI '${aci_name}'"
      return 0
    fi

    if [[ "$attempt" -lt 12 ]]; then
      warn "Waiting for managed identity '${aci_name}' to become assignable..."
      sleep 10
    fi
  done

  err "Failed to assign '${STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE}' to ACI '${aci_name}'"
  return 1
}

wait_for_aci_instances_completion() {
  local aci_names=("$@")

  if $DRY_RUN || [[ "${#aci_names[@]}" -eq 0 ]]; then
    return 0
  fi

  log "Waiting for ACI instances to complete..."
  local all_done=false
  while ! $all_done; do
    all_done=true
    for aci_name in "${aci_names[@]}"; do
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
}

get_max_aci_index() {
  if $DRY_RUN; then
    echo "0"
    return 0
  fi

  local max_idx=0
  local aci_names
  aci_names=$(az container list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?starts_with(name, '${ACI_PREFIX}-')].name" -o tsv 2>/dev/null || true)

  while IFS= read -r aci_name; do
    [[ -z "$aci_name" ]] && continue
    local suffix="${aci_name#${ACI_PREFIX}-}"
    if [[ "$suffix" =~ ^[0-9]+$ ]]; then
      local numeric_suffix=$((10#$suffix))
      if (( numeric_suffix > max_idx )); then
        max_idx=$numeric_suffix
      fi
    fi
  done <<< "$aci_names"

  echo "$max_idx"
}

initialize_azdatamaker_infra() {
  log "Setting up Azure Container Registry '${ACR_NAME}'..."

  if ! $DRY_RUN && az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
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

  run_or_dry "az acr update \
    --name '${ACR_NAME}' \
    --resource-group '${RESOURCE_GROUP}' \
    --admin-enabled true \
    --output none"

  log "Building AzDataMaker container image from Azure/AzDataMaker..."
  run_or_dry "az acr build \
    --resource-group '${RESOURCE_GROUP}' \
    --registry '${ACR_NAME}' \
    '${AZDATAMAKER_GIT_URL}' \
    -f '${AZDATAMAKER_DOCKERFILE}' \
    --image '${AZDATAMAKER_IMAGE}' \
    --no-logs \
    --output none"
  ok "AzDataMaker image ready"

  if $DRY_RUN; then
    ACR_SERVER="${ACR_NAME}.azurecr.io"
    ACR_USER="<dry-run>"
    ACR_PWD="<dry-run>"
    SOURCE_STORAGE_ID="/subscriptions/<subscription>/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${SOURCE_STORAGE}"
    SOURCE_STORAGE_URI="https://${SOURCE_STORAGE}.blob.core.windows.net/"
    return 0
  fi

  ACR_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer -o tsv)
  ACR_USER=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query username -o tsv)
  ACR_PWD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)
  SOURCE_STORAGE_ID=$(az storage account show --name "$SOURCE_STORAGE" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv)
  SOURCE_STORAGE_URI=$(az storage account show --name "$SOURCE_STORAGE" --resource-group "$RESOURCE_GROUP" --query "primaryEndpoints.blob" -o tsv)
  return 0
}

deploy_azdatamaker_instance() {
  local aci_name="$1"
  local container_names="$2"
  local report_status_increment="$3"
  local reuse_compatible="${4:-false}"

  if ! $DRY_RUN && az container show --name "$aci_name" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    if [[ "$reuse_compatible" == "true" ]] && aci_uses_managed_identity_storage_uri "$aci_name"; then
      ok "ACI '${aci_name}' already exists — reusing"
      local existing_principal_id
      existing_principal_id=$(az container show \
        --name "$aci_name" \
        --resource-group "$RESOURCE_GROUP" \
        --query "identity.principalId" -o tsv 2>/dev/null || echo "")
      if [[ -n "$existing_principal_id" ]]; then
        ensure_storage_blob_data_contributor "$existing_principal_id" "$SOURCE_STORAGE_ID" "$aci_name"
      fi
      return 0
    fi

    if [[ "$reuse_compatible" == "true" ]]; then
      warn "ACI '${aci_name}' exists but does not use managed identity + StorageAccountUri — recreating"
    else
      warn "ACI '${aci_name}' already exists — recreating"
    fi

    az container delete \
      --name "$aci_name" \
      --resource-group "$RESOURCE_GROUP" \
      --yes \
      --output none
    wait_for_aci_deleted "$aci_name"
  fi

  run_or_dry "az container create \
    --name '${aci_name}' \
    --resource-group '${RESOURCE_GROUP}' \
    --location '${SOURCE_REGION}' \
    --os-type Linux \
    --cpu 1 \
    --memory 1 \
    --registry-login-server '${ACR_SERVER}' \
    --registry-username '${ACR_USER}' \
    --registry-password '${ACR_PWD}' \
    --image '${ACR_SERVER}/${AZDATAMAKER_IMAGE}' \
    --restart-policy Never \
    --assign-identity \
    --environment-variables \
      FileCount='${FILES_PER_INSTANCE}' \
      MaxFileSize='${MAX_FILE_SIZE}' \
      MinFileSize='${MIN_FILE_SIZE}' \
      ReportStatusIncrement='${report_status_increment}' \
      BlobContainers='${container_names}' \
      RandomFileContents='false' \
      StorageAccountUri='${SOURCE_STORAGE_URI}' \
    --output none"

  if ! $DRY_RUN; then
    local principal_id
    principal_id=$(wait_for_aci_principal_id "$aci_name")
    ensure_storage_blob_data_contributor "$principal_id" "$SOURCE_STORAGE_ID" "$aci_name"
  fi

  ok "ACI '${aci_name}' deployed"
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
  echo "  │ ACI count:          ${ACI_COUNT} (AzDataMaker only)"
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
