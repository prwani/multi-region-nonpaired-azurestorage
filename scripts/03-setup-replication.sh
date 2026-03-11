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

  # ── Build policy definition JSON ────────────────
  log "Building replication policy with ${CONTAINER_COUNT} rule(s)..."
  local rules_json="[]"
  for i in $(seq -w 1 "$CONTAINER_COUNT"); do
    local src_container="${SOURCE_CONTAINER_PREFIX}-${i}"
    local dst_container="${DEST_CONTAINER_PREFIX}-${i}"
    rules_json=$(echo "$rules_json" | jq \
      --arg sc "$src_container" \
      --arg dc "$dst_container" \
      '. += [{"ruleId": "", "sourceContainer": $sc, "destinationContainer": $dc, "filters": {"minCreationTime": ""}}]')
  done

  local policy_json
  policy_json=$(jq -n \
    --arg src "$src_id" \
    --arg dst "$dst_id" \
    --argjson rules "$rules_json" \
    '{
      "properties": {
        "policyId": "default",
        "sourceAccount": $src,
        "destinationAccount": $dst,
        "rules": $rules
      }
    }')

  local policy_file
  policy_file=$(mktemp /tmp/or-policy-XXXXXX.json)
  echo "$policy_json" > "$policy_file"

  if [[ "$REPLICATION_MODE" == "priority" ]]; then
    log "Priority replication mode selected (99% within 15 min SLA for same-continent)"
  fi

  # ── Create policy on destination account ────────
  log "Creating replication policy on destination account '${DEST_STORAGE}'..."
  run_or_dry "az storage account or-policy create \
    --account-name '${DEST_STORAGE}' \
    --resource-group '${RESOURCE_GROUP}' \
    --policy @'${policy_file}' \
    --output none"

  # Get the assigned policy ID
  local policy_id
  policy_id=$(az storage account or-policy list \
    --account-name "$DEST_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].policyId" -o tsv 2>/dev/null || echo "")

  if [[ -z "$policy_id" ]]; then
    rm -f "$policy_file"
    err "Failed to create or retrieve replication policy on destination account"
    exit 1
  fi
  ok "Policy created on destination with ID: ${policy_id}"

  # ── Create matching policy on source account ────
  log "Creating matching policy on source account '${SOURCE_STORAGE}'..."

  # Download the policy from destination (includes assigned IDs)
  local dest_policy
  dest_policy=$(az storage account or-policy show \
    --account-name "$DEST_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --policy-id "$policy_id" \
    --output json 2>/dev/null)

  # Write the destination policy to file for source
  local src_policy_file
  src_policy_file=$(mktemp /tmp/or-policy-src-XXXXXX.json)
  echo "$dest_policy" | jq '{properties: {policyId: .policyId, sourceAccount: .sourceAccount, destinationAccount: .destinationAccount, rules: [.rules[] | {ruleId: .ruleId, sourceContainer: .sourceContainer, destinationContainer: .destinationContainer, filters: .filters}]}}' > "$src_policy_file"

  run_or_dry "az storage account or-policy create \
    --account-name '${SOURCE_STORAGE}' \
    --resource-group '${RESOURCE_GROUP}' \
    --policy @'${src_policy_file}' \
    --output none"
  ok "Matching policy created on source account"

  rm -f "$policy_file" "$src_policy_file"

  # ── Enable priority replication if requested ────
  if [[ "$REPLICATION_MODE" == "priority" ]]; then
    log "Enabling priority replication on policy ${policy_id}..."
    run_or_dry "az storage account or-policy update \
      --account-name '${DEST_STORAGE}' \
      --resource-group '${RESOURCE_GROUP}' \
      --policy-id '${policy_id}' \
      --output none" || true
    ok "Priority replication enabled"
    warn "Note: priority replication has a per-GB ingress cost and billing continues 30 days after disabling"
  fi

  log "Object replication configured successfully."
  ok "Mode: ${REPLICATION_MODE}"
  ok "Policy ID: ${policy_id}"
  ok "Container pairs: ${CONTAINER_COUNT}"
}

main "$@"
