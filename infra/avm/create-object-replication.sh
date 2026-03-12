#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP=''
DEPLOYMENT_NAME=''
REPLICATION_MODE='default'
MIN_CREATION_TIME='1601-01-01T00:00:00Z'

usage() {
  cat <<'EOF'
Usage: ./infra/avm/create-object-replication.sh --resource-group <name> --deployment-name <name> [options]

Creates the object replication policy pair after the AVM companion deployment has provisioned
the storage accounts, containers, and optional security foundations.

Options:
  --resource-group <name>        Resource group that holds the companion deployment
  --deployment-name <name>       Azure deployment name used for infra/avm/main.bicep
  --replication-mode <mode>      default | priority (default: default)
  --min-creation-time <value>    Copy scope start timestamp (default: 1601-01-01T00:00:00Z)
  -h, --help                     Show this help

Notes:
  * The script expects the deployment outputs from infra/avm/main.bicep.
  * The destination containers become read-only once the policy is active.
  * The script is intentionally conservative: if either account already has an object replication
    policy, it exits instead of trying to replace it in place.
EOF
}

log() {
  printf '==> %s\n' "$*"
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Missing required tool: $1"
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --deployment-name)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    --replication-mode)
      REPLICATION_MODE="$2"
      shift 2
      ;;
    --min-creation-time)
      MIN_CREATION_TIME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$DEPLOYMENT_NAME" ]]; then
  err '--resource-group and --deployment-name are required.'
  usage
  exit 1
fi

if [[ "$REPLICATION_MODE" != 'default' && "$REPLICATION_MODE" != 'priority' ]]; then
  err "--replication-mode must be 'default' or 'priority'."
  exit 1
fi

require_tool az
require_tool jq

log "Reading deployment outputs from '$DEPLOYMENT_NAME' in resource group '$RESOURCE_GROUP'..."
outputs_json=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs \
  --output json)

source_name=$(jq -r '.sourceStorageAccountName.value // empty' <<<"$outputs_json")
destination_name=$(jq -r '.destinationStorageAccountName.value // empty' <<<"$outputs_json")
source_id=$(jq -r '.sourceStorageAccountResourceId.value // empty' <<<"$outputs_json")
destination_id=$(jq -r '.destinationStorageAccountResourceId.value // empty' <<<"$outputs_json")
pair_count=$(jq -r '.containerPairs.value | length' <<<"$outputs_json")

if [[ -z "$source_name" || -z "$destination_name" || -z "$source_id" || -z "$destination_id" || "$pair_count" == '0' ]]; then
  err 'The deployment outputs are missing one or more required values.'
  err 'Make sure the infrastructure was deployed with infra/avm/main.bicep.'
  exit 1
fi

existing_source_policies=$(az storage account or-policy list \
  --account-name "$source_name" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'length(@)' \
  --output tsv)

existing_destination_policies=$(az storage account or-policy list \
  --account-name "$destination_name" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'length(@)' \
  --output tsv)

if [[ "${existing_source_policies:-0}" != '0' || "${existing_destination_policies:-0}" != '0' ]]; then
  err 'One or both storage accounts already have an object replication policy.'
  err 'Delete the existing policy pair before re-running this bootstrap step.'
  exit 1
fi

if (( pair_count > 10 )); then
  # ── JSON policy approach (required for >10 container pairs) ──
  log "Using JSON policy definition (required for >10 container pairs)"

  # Build rules array from all container pairs
  rules_json=$(jq -r '[.containerPairs.value[] | {sourceContainer: .source, destinationContainer: .destination, filters: {minCreationTime: "'"$MIN_CREATION_TIME"'"}}]' <<<"$outputs_json")

  policy_json=$(jq -n \
    --arg src "$source_id" \
    --arg dst "$destination_id" \
    --argjson rules "$rules_json" \
    '{properties: {sourceAccount: $src, destinationAccount: $dst, rules: $rules}}')

  if [[ "$REPLICATION_MODE" == 'priority' ]]; then
    policy_json=$(echo "$policy_json" | jq '.properties.priorityReplication = true')
  fi

  json_policy_file=$(mktemp)
  echo "$policy_json" > "$json_policy_file"

  log "Creating destination-side policy with all ${pair_count} rules (${REPLICATION_MODE})..."
  az storage account or-policy create \
    --account-name "$destination_name" \
    --resource-group "$RESOURCE_GROUP" \
    --policy "@${json_policy_file}" \
    --output none

  rm -f "$json_policy_file"

else
  # ── Inline approach (<=10 container pairs) ─────
  first_pair=$(jq -r '.containerPairs.value[0] | @base64' <<<"$outputs_json")
  first_source_container=$(base64 -d <<<"$first_pair" | jq -r '.source')
  first_destination_container=$(base64 -d <<<"$first_pair" | jq -r '.destination')

  log "Creating destination-side policy for ${first_source_container} -> ${first_destination_container} (${REPLICATION_MODE})..."
  create_cmd=(
    az storage account or-policy create
    --account-name "$destination_name"
    --resource-group "$RESOURCE_GROUP"
    --source-account "$source_id"
    --destination-account "$destination_id"
    --source-container "$first_source_container"
    --destination-container "$first_destination_container"
    --min-creation-time "$MIN_CREATION_TIME"
    --output none
  )

  if [[ "$REPLICATION_MODE" == 'priority' ]]; then
    create_cmd+=(--priority-replication true)
  fi

  "${create_cmd[@]}"
fi

policy_id=''
for _ in {1..12}; do
  policy_id=$(az storage account or-policy list \
    --account-name "$destination_name" \
    --resource-group "$RESOURCE_GROUP" \
    --query '[0].policyId' \
    --output tsv 2>/dev/null || true)

  [[ -n "$policy_id" ]] && break
  sleep 5
done

if [[ -z "$policy_id" ]]; then
  err 'The destination policy was created, but the policy ID could not be read back.'
  exit 1
fi

if (( pair_count > 1 && pair_count <= 10 )); then
  log "Adding $((pair_count - 1)) additional container rule(s)..."
  while IFS= read -r encoded_pair; do
    [[ -z "$encoded_pair" ]] && continue

    source_container=$(base64 -d <<<"$encoded_pair" | jq -r '.source')
    destination_container=$(base64 -d <<<"$encoded_pair" | jq -r '.destination')

    az storage account or-policy rule add \
      --account-name "$destination_name" \
      --resource-group "$RESOURCE_GROUP" \
      --policy-id "$policy_id" \
      --source-container "$source_container" \
      --destination-container "$destination_container" \
      --min-creation-time "$MIN_CREATION_TIME" \
      --output none
  done < <(jq -r '.containerPairs.value[1:][] | @base64' <<<"$outputs_json")
fi

policy_file=$(mktemp)
trap 'rm -f "$policy_file"' EXIT

log 'Reading the destination policy so the source-side policy can reuse the generated rule IDs...'
az storage account or-policy show \
  --account-name "$destination_name" \
  --resource-group "$RESOURCE_GROUP" \
  --policy-id "$policy_id" \
  --output json > "$policy_file"

log 'Creating the matching source-side policy...'
az storage account or-policy create \
  --account-name "$source_name" \
  --resource-group "$RESOURCE_GROUP" \
  --policy "@${policy_file}" \
  --output none

log "Object replication is active. Policy ID: $policy_id"
log "Mode: $REPLICATION_MODE"
log 'Tip: keep monitoring enabled and validate replication metrics before tightening additional network controls.'
