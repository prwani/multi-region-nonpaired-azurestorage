#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 03-setup-replication.sh — Configure object replication between storage accounts
#
# Creates destination containers and sets up replication policy with rules
# for each container pair. Supports default and priority replication modes.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Set up object replication policy between source and destination accounts."
  echo ""
  echo "Options:"
  echo "  --replication-mode <mode>  'default' or 'priority' (default: default)"
  echo "  --container-count <n>      Number of container pairs (default: 5)"
  echo "  --subscription <id>        Azure subscription ID"
  echo "  --dry-run                  Preview without executing"
  echo "  -h, --help                 Show this help"
}

main() {
  load_config
  parse_common_args "$@"
  set_subscription

  require_tool az
  require_tool jq

  # ── Create destination containers ───────────────
  log "Creating ${CONTAINER_COUNT} destination container(s)..."

  for i in $(seq -w 1 "$CONTAINER_COUNT"); do
    local cname="${DEST_CONTAINER_PREFIX}-${i}"
    local exists
    exists=$(az storage container exists \
      --name "$cname" \
      --account-name "$DEST_STORAGE" \
      --auth-mode login \
      --query "exists" -o tsv 2>/dev/null || echo "false")
    if [[ "$exists" == "true" ]]; then
      ok "Container '${cname}' already exists — reusing"
    else
      run_or_dry "az storage container create \
        --name '${cname}' \
        --account-name '${DEST_STORAGE}' \
        --auth-mode login \
        --output none"
      ok "Container '${cname}' created"
    fi
  done

  # ── Get account resource IDs ────────────────────
  local src_id dst_id
  src_id=$(az storage account show \
    --name "$SOURCE_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "id" -o tsv)
  dst_id=$(az storage account show \
    --name "$DEST_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "id" -o tsv)

  if [[ "$REPLICATION_MODE" == "priority" ]]; then
    log "Priority replication mode selected (99% within 15 min SLA for same-continent)"
  fi

  # ── Create policy with the first rule ───────────
  # Use min-creation-time '1601-01-01T00:00:00Z' to replicate ALL objects (existing + new)
  local first_src="${SOURCE_CONTAINER_PREFIX}-1"
  local first_dst="${DEST_CONTAINER_PREFIX}-1"
  log "Creating replication policy on destination account '${DEST_STORAGE}'..."
  log "Copy scope: all objects (existing + new)"

  local create_cmd="az storage account or-policy create \
    --account-name '${DEST_STORAGE}' \
    --resource-group '${RESOURCE_GROUP}' \
    --source-account '${src_id}' \
    --destination-account '${dst_id}' \
    --destination-container '${first_dst}' \
    --source-container '${first_src}' \
    --min-creation-time '1601-01-01T00:00:00Z'"

  if [[ "$REPLICATION_MODE" == "priority" ]]; then
    create_cmd="${create_cmd} --priority-replication true"
  fi

  create_cmd="${create_cmd} --output none"
  run_or_dry "$create_cmd"

  # Get the assigned policy ID
  local policy_id
  policy_id=$(az storage account or-policy list \
    --account-name "$DEST_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].policyId" -o tsv 2>/dev/null || echo "")

  if [[ -z "$policy_id" ]]; then
    err "Failed to create or retrieve replication policy on destination account"
    exit 1
  fi
  ok "Policy created on destination with ID: ${policy_id}"
  ok "Rule: ${first_src} → ${first_dst}"

  # ── Add remaining rules ─────────────────────────
  if [[ "$CONTAINER_COUNT" -gt 1 ]]; then
    log "Adding remaining $((CONTAINER_COUNT - 1)) rule(s)..."
    for i in $(seq 2 "$CONTAINER_COUNT"); do
      local src_container="${SOURCE_CONTAINER_PREFIX}-${i}"
      local dst_container="${DEST_CONTAINER_PREFIX}-${i}"
      run_or_dry "az storage account or-policy rule add \
        --account-name '${DEST_STORAGE}' \
        --resource-group '${RESOURCE_GROUP}' \
        --policy-id '${policy_id}' \
        --source-container '${src_container}' \
        --destination-container '${dst_container}' \
        --min-creation-time '1601-01-01T00:00:00Z' \
        --output none"
      ok "Rule: ${src_container} → ${dst_container}"
    done
  fi

  # ── Create matching policy on source account ────
  log "Creating matching policy on source account '${SOURCE_STORAGE}'..."

  # Get the full policy from destination (includes assigned rule IDs)
  local dest_policy
  dest_policy=$(az storage account or-policy show \
    --account-name "$DEST_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --policy-id "$policy_id" \
    --output json 2>/dev/null)

  # Write policy to temp file for source account
  local policy_file
  policy_file=$(mktemp /tmp/or-policy-XXXXXX.json)
  echo "$dest_policy" > "$policy_file"

  run_or_dry "az storage account or-policy create \
    --account-name '${SOURCE_STORAGE}' \
    --resource-group '${RESOURCE_GROUP}' \
    --policy @'${policy_file}' \
    --output none"
  ok "Matching policy created on source account"

  rm -f "$policy_file"

  # ── Priority replication note ───────────────────
  if [[ "$REPLICATION_MODE" == "priority" ]]; then
    ok "Priority replication enabled"
    warn "Note: priority replication has a per-GB ingress cost and billing continues 30 days after disabling"
  fi

  log "Object replication configured successfully."
  ok "Mode: ${REPLICATION_MODE}"
  ok "Policy ID: ${policy_id}"
  ok "Container pairs: ${CONTAINER_COUNT}"
}

main "$@"
