# Blog 2 — AVM Companion Track for Production-Oriented Azure Storage Object Replication

The original walkthrough in this repo is intentionally hands-on. It is the best path when you want to learn Azure Blob object replication from scratch, compare regions, generate test data, and watch replication behavior with a CLI-first workflow.

But that is not how most platform teams roll storage into production.

In a real environment, architects and DevOps teams usually want a second track:

- repeatable infrastructure as code
- secure-by-default storage settings
- optional integration points for platform-owned services such as Key Vault, private DNS, private endpoints, and Log Analytics
- a clean operational boundary between **provisioning** and **turning on replication**

That is exactly what the new **AVM companion track** adds.

## Why add a second track at all?

Azure Object Replication is easy to explain with scripts, but production environments care about more than “can I copy blobs from region A to region B?” They care about:

- whether the deployment pattern fits an existing landing zone
- how encryption is governed
- how network isolation is introduced without breaking replication
- where metrics and logs land
- how much operational ceremony is acceptable before a destination account becomes read-only

The companion track does **not** replace the CLI demo. It complements it.

## What the AVM companion path does differently

The companion track uses **Azure Verified Modules (AVM)** for the storage account foundation. Instead of making the repo more enterprise-like by bolting on a huge platform template, it stays deliberately small and practical:

- deploys the two storage accounts with Bicep + AVM
- enables source-side **change feed** and **blob versioning**
- enables destination-side **blob versioning**
- creates the source and destination containers up front
- routes storage metrics and blob logs into Log Analytics
- optionally binds both accounts to a **customer-managed key**
- optionally adds **private endpoints** to existing network assets

This is enough to be useful in a real implementation review without pretending to be a full landing zone.

## Why the replication policy is still a post-deploy step

This was a conscious design choice.

The storage prerequisites fit Bicep and AVM very well. The actual replication policy is a little different. It is the moment where you make destination containers part of a live replication topology and accept the operational consequences.

In the companion track, that activation happens with a **small post-deploy Azure CLI step** (`infra/avm/create-object-replication.sh`). That split gives a few practical benefits:

1. **Priority replication stays explicit.** Teams can choose default replication or priority replication at activation time instead of hiding that decision inside a generic template.
2. **Change control is cleaner.** Infrastructure can be provisioned, reviewed, and approved before the replication policy makes the destination side read-only.
3. **The boundary is honest.** AVM is used where it adds the most value: repeatable resource provisioning and secure defaults. The CLI is used where an operator often wants an intentional final switch.

For the actual deployment commands and parameter-file examples, see [`infra/avm/README.md`](infra/avm/README.md).

## CMK: useful, powerful, and operationally expensive

Customer-managed keys are one of the clearest examples of why a companion track matters.

In a demo, platform-managed keys are usually enough. In production, many organizations need CMK for governance, separation of duties, or regulatory reasons. The companion path treats CMK realistically:

- the template assumes the **Key Vault and key already exist**
- it creates a **user-assigned managed identity** for storage encryption
- it grants the identity the **Key Vault Crypto Service Encryption User** role on the selected key
- it configures both storage accounts to use that key

That is a better production story than creating an ad hoc Key Vault inside the same demo template. In most enterprises, key lifecycle, rotation, purge protection, and access reviews belong to a platform or security team.

The trade-off is operational coupling. If key access is misconfigured, rotated badly, or blocked by network policy, storage availability can be affected. CMK is not just a security switch; it is an availability dependency.

## Private endpoints: worth it, but test the posture you actually want

Private endpoints are another feature that looks simple on a slide and becomes nuanced in a real deployment.

The companion track supports storage private endpoints, but it assumes the **subnets and private DNS zone already exist**. That is intentional. VNets, routing, and DNS are usually landing-zone concerns, not something a storage sample should own long term.

The selected pattern is pragmatic:

- storage private endpoints for application traffic
- firewall deny by default
- `AzureServices` bypass kept in place for the Azure-managed paths that replication and diagnostics may still rely on

This is a strong production baseline because it improves isolation without forcing every team into a brittle “disable everything public immediately” posture. If your organization wants fully disabled public network access, validate that stance with your actual tooling, DNS model, monitoring path, and replication expectations first.

## Security defaults that matter

The AVM companion path hardens the basics so they are not left as follow-up tasks:

- blob public access disabled
- HTTPS only
- TLS 1.2 minimum
- infrastructure encryption enabled
- shared key access disabled by default

That last point still matters, but the repo's broader runtime story has also improved. The main CLI demo now defaults to **login-based local uploads**, and the optional AzDataMaker path uses **managed identity**. The companion track keeps shared key disabled unless a downstream requirement explicitly forces an exception, and it simply leaves benchmark resources out of scope.

## Monitoring and operations

Replication is not finished when the policy is created. It is finished when operators can prove it is healthy.

The companion track therefore enables monitoring from the start. It can send storage account metrics and blob service logs into either:

- a small workspace created in the deployment resource group, or
- an existing shared Log Analytics workspace

That gives architects and operators a better starting point for:

- replication health checks
- lag investigations
- security and audit reviews
- post-change validation after network or CMK updates

The template intentionally stops short of creating a complete alerting framework. Most teams already have a central observability standard, and this repo should plug into that rather than compete with it.

## When to choose the CLI demo path vs the AVM companion path

Use the **CLI demo path** when you want:

- the fastest end-to-end learning experience
- benchmarking with local uploads or the optional AzDataMaker path
- a guided walkthrough of object replication behavior
- experimentation with regions, data volume, or demo-friendly settings

Use the **AVM companion path** when you want:

- reusable Bicep for the storage foundation
- secure defaults that resemble production expectations
- optional CMK integration without inventing a whole key-management platform inside the sample
- optional private endpoint integration with existing landing-zone assets
- a cleaner split between infrastructure deployment and replication activation

In other words: the CLI path teaches the feature; the AVM companion path shows how to carry it into a production conversation.

## End-to-End Walkthrough: AVM Companion with CMK and Private Endpoints

The sections above explain the *why* behind the companion track. This section is the *how* — a complete, copy-paste-ready walkthrough that reproduces the full advanced AVM path from zero to validated replication and back to clean.

Every command below uses placeholder values where you need to substitute your own. Replace `<subscription-id>`, storage account names, and similar tokens before running.

### Variables used throughout

Set these once and the rest of the walkthrough will reference them:

```bash
SUBSCRIPTION="<subscription-id>"
RG="rg-avm-e2e-test"
LOCATION_SOURCE="swedencentral"
LOCATION_DEST="norwayeast"
KV_NAME="kv-objrepl-e2e"
KEY_NAME="storage-cmk"
VNET_SOURCE="vnet-source"
VNET_DEST="vnet-dest"
SNET_SOURCE_PE="snet-source-pe"
SNET_DEST_PE="snet-dest-pe"
DNS_ZONE="privatelink.blob.core.windows.net"
DEPLOYMENT_NAME="avm-e2e"
SOURCE_STORAGE="stobjreplsrce2e"   # must be globally unique
DEST_STORAGE="stobjrepldste2e"     # must be globally unique
```

---

### Phase 1 — Create supporting platform assets

Before deploying the AVM companion, you need the platform assets it integrates with: a Key Vault with a key, VNets with PE subnets, and a private DNS zone.

```bash
# Resource group
az group create --name "$RG" --location "$LOCATION_SOURCE"

# Key Vault with purge protection (required for CMK)
az keyvault create \
  --name "$KV_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION_SOURCE" \
  --enable-purge-protection true \
  --enable-rbac-authorization true

# Create the CMK key
az keyvault key create \
  --vault-name "$KV_NAME" \
  --name "$KEY_NAME" \
  --kty RSA \
  --size 2048

# Grant yourself Key Vault Crypto Officer so the deployment can create role assignments
CURRENT_USER=$(az ad signed-in-user show --query id --output tsv)
KV_ID=$(az keyvault show --name "$KV_NAME" --resource-group "$RG" --query id --output tsv)

az role assignment create \
  --assignee "$CURRENT_USER" \
  --role "Key Vault Crypto Officer" \
  --scope "$KV_ID"
```

```bash
# Source-region VNet with PE subnet
az network vnet create \
  --name "$VNET_SOURCE" \
  --resource-group "$RG" \
  --location "$LOCATION_SOURCE" \
  --address-prefix 10.0.0.0/16

az network vnet subnet create \
  --name "$SNET_SOURCE_PE" \
  --resource-group "$RG" \
  --vnet-name "$VNET_SOURCE" \
  --address-prefix 10.0.1.0/24

# Destination-region VNet with PE subnet
az network vnet create \
  --name "$VNET_DEST" \
  --resource-group "$RG" \
  --location "$LOCATION_DEST" \
  --address-prefix 10.1.0.0/16

az network vnet subnet create \
  --name "$SNET_DEST_PE" \
  --resource-group "$RG" \
  --vnet-name "$VNET_DEST" \
  --address-prefix 10.1.1.0/24
```

```bash
# Private DNS zone and VNet links
az network private-dns zone create \
  --name "$DNS_ZONE" \
  --resource-group "$RG"

az network private-dns link vnet create \
  --name "link-source" \
  --resource-group "$RG" \
  --zone-name "$DNS_ZONE" \
  --virtual-network "$VNET_SOURCE" \
  --registration-enabled false

az network private-dns link vnet create \
  --name "link-dest" \
  --resource-group "$RG" \
  --zone-name "$DNS_ZONE" \
  --virtual-network "/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${VNET_DEST}" \
  --registration-enabled false
```

**Verify Phase 1:**

```bash
az keyvault key show --vault-name "$KV_NAME" --name "$KEY_NAME" --query key.kid --output tsv
az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_SOURCE" --name "$SNET_SOURCE_PE" --query id --output tsv
az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_DEST" --name "$SNET_DEST_PE" --query id --output tsv
az network private-dns zone show --resource-group "$RG" --name "$DNS_ZONE" --query id --output tsv
```

---

### Phase 2 — Deploy the AVM companion with CMK and private endpoints

Build a `.bicepparam` file that points at the real resource IDs you just created, then deploy:

```bash
# Collect resource IDs
KV_RESOURCE_ID=$(az keyvault show --name "$KV_NAME" --resource-group "$RG" --query id --output tsv)
SOURCE_SNET_ID=$(az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_SOURCE" --name "$SNET_SOURCE_PE" --query id --output tsv)
DEST_SNET_ID=$(az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_DEST" --name "$SNET_DEST_PE" --query id --output tsv)
DNS_ZONE_ID=$(az network private-dns zone show --resource-group "$RG" --name "$DNS_ZONE" --query id --output tsv)

# Generate a temporary .bicepparam
cat > /tmp/e2e-advanced.bicepparam <<PARAMS
using './infra/avm/main.bicep'

param destinationLocation = '${LOCATION_DEST}'
param sourceStorageAccountName = '${SOURCE_STORAGE}'
param destinationStorageAccountName = '${DEST_STORAGE}'
param containerCount = 3
param allowSharedKeyAccess = false
param enableMonitoring = true

param enableCmk = true
param keyVaultResourceId = '${KV_RESOURCE_ID}'
param keyName = '${KEY_NAME}'

param enablePrivateEndpoints = true
param sourcePrivateEndpointSubnetResourceId = '${SOURCE_SNET_ID}'
param destinationPrivateEndpointSubnetResourceId = '${DEST_SNET_ID}'
param blobPrivateDnsZoneResourceId = '${DNS_ZONE_ID}'

param tags = {
  environment: 'e2e-test'
  deploymentTrack: 'avm-companion'
}
PARAMS
```

```bash
# Deploy
az deployment group create \
  --resource-group "$RG" \
  --name "$DEPLOYMENT_NAME" \
  --template-file infra/avm/main.bicep \
  --parameters /tmp/e2e-advanced.bicepparam
```

**Verify Phase 2:**

```bash
# Confirm deployment outputs
az deployment group show \
  --resource-group "$RG" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs \
  --output json

# Confirm storage accounts exist
az storage account show --name "$SOURCE_STORAGE" --resource-group "$RG" --query name --output tsv
az storage account show --name "$DEST_STORAGE" --resource-group "$RG" --query name --output tsv
```

The deployment creates: 2 storage accounts, 3 container pairs (`source-01`/`dest-01` through `source-03`/`dest-03`), a user-assigned managed identity for CMK, Log Analytics workspace, diagnostic settings, and private endpoints for both accounts.

---

### Phase 3 — Activate object replication

```bash
./infra/avm/create-object-replication.sh \
  --resource-group "$RG" \
  --deployment-name "$DEPLOYMENT_NAME"
```

**Verify Phase 3:**

```bash
# Confirm policies exist on both sides
az storage account or-policy list --account-name "$SOURCE_STORAGE" --resource-group "$RG" --output table
az storage account or-policy list --account-name "$DEST_STORAGE" --resource-group "$RG" --output table
```

> **Note on >10 container pairs:** If you set `containerCount` higher than 10, the activation script automatically switches to a [JSON policy definition file](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-configure?tabs=azure-cli#configure-object-replication-using-a-json-file) that defines all rules in a single `or-policy create` call. This is the same approach used by the CLI demo scripts.

---

### Phase 4 — Data-path verification

With private endpoints enabled and the firewall set to Deny, you need a temporary firewall exception to upload a test blob from your workstation:

```bash
# Add your client IP to the source storage firewall
CLIENT_IP=$(curl -s https://api.ipify.org)
az storage account network-rule add \
  --account-name "$SOURCE_STORAGE" \
  --resource-group "$RG" \
  --ip-address "$CLIENT_IP"

# Wait for the firewall rule to propagate
sleep 30

# Upload a test blob
echo "e2e-test-data" > /tmp/e2e-test.txt
az storage blob upload \
  --account-name "$SOURCE_STORAGE" \
  --container-name "source-01" \
  --name "e2e-test.txt" \
  --file /tmp/e2e-test.txt \
  --auth-mode login

# Wait for replication (~60 seconds is usually enough for small blobs)
sleep 60

# Check the blob on the destination side
az storage blob show \
  --account-name "$DEST_STORAGE" \
  --container-name "dest-01" \
  --name "e2e-test.txt" \
  --auth-mode login \
  --query 'properties.replicationStatus' \
  --output tsv
```

You should see `complete`. If you see `pending`, wait another 30–60 seconds and try again.

> **Caveat:** This temporary IP exception is only needed for data-path testing from outside the VNet. In production, uploads would come from compute inside the VNet or via a VPN/ExpressRoute path.

```bash
# Remove the temporary IP rule when you are done
az storage account network-rule remove \
  --account-name "$SOURCE_STORAGE" \
  --resource-group "$RG" \
  --ip-address "$CLIENT_IP"
```

---

### Phase 5 — Security posture verification

Confirm the deployment's security controls are in place:

```bash
# CMK — verify encryption key source
az storage account show --name "$SOURCE_STORAGE" --resource-group "$RG" \
  --query 'encryption.keySource' --output tsv
# Expected: Microsoft.Keyvault

az storage account show --name "$DEST_STORAGE" --resource-group "$RG" \
  --query 'encryption.keySource' --output tsv
# Expected: Microsoft.Keyvault

# Private endpoints — verify connection state
az network private-endpoint-connection list \
  --id "$(az storage account show --name "$SOURCE_STORAGE" --resource-group "$RG" --query id --output tsv)" \
  --query '[].properties.privateLinkServiceConnectionState.status' --output tsv
# Expected: Approved

az network private-endpoint-connection list \
  --id "$(az storage account show --name "$DEST_STORAGE" --resource-group "$RG" --query id --output tsv)" \
  --query '[].properties.privateLinkServiceConnectionState.status' --output tsv
# Expected: Approved

# Firewall — verify default action
az storage account show --name "$SOURCE_STORAGE" --resource-group "$RG" \
  --query 'networkRuleSet.defaultAction' --output tsv
# Expected: Deny

az storage account show --name "$DEST_STORAGE" --resource-group "$RG" \
  --query 'networkRuleSet.defaultAction' --output tsv
# Expected: Deny
```

---

### Phase 6 — Cleanup

Clean up in order: replication policies first (both sides), then the resource group.

```bash
# Get the policy ID
POLICY_ID=$(az storage account or-policy list \
  --account-name "$SOURCE_STORAGE" \
  --resource-group "$RG" \
  --query '[0].policyId' --output tsv)

# Delete the source-side policy first, then the destination-side policy
az storage account or-policy delete \
  --account-name "$SOURCE_STORAGE" \
  --resource-group "$RG" \
  --policy-id "$POLICY_ID"

az storage account or-policy delete \
  --account-name "$DEST_STORAGE" \
  --resource-group "$RG" \
  --policy-id "$POLICY_ID"

# Delete the resource group (deletes storage accounts, VNets, PEs, DNS zone, etc.)
az group delete --name "$RG" --yes --no-wait
```

> **Key Vault purge caveat:** Because the Key Vault was created with `--enable-purge-protection true`, deleting the resource group only **soft-deletes** the vault. It remains in the soft-deleted state for the retention period (default 90 days) and must be purged manually afterward if you want to reclaim the name:
>
> ```bash
> az keyvault purge --name "$KV_NAME" --location "$LOCATION_SOURCE"
> ```
>
> If you do not need purge protection for a test run, you can skip `--enable-purge-protection` in Phase 1 — but note that CMK in production almost always requires purge protection.

```bash
# Clean up temporary files
rm -f /tmp/e2e-advanced.bicepparam /tmp/e2e-test.txt
```

---

### Caveats and lessons learned

1. **Cross-region private endpoints require co-located VNets.** Each storage account's private endpoint must live in a subnet within the same region as that account. That is why this walkthrough creates two VNets: one in `swedencentral` and one in `norwayeast`.

2. **Data-path testing requires a temporary firewall exception.** With `defaultAction: Deny`, uploading test blobs from a local workstation requires adding your client IP to the firewall temporarily. In production, this would be unnecessary because compute workloads would access storage through the VNet.

3. **Key Vault purge protection has lasting side effects.** The vault remains soft-deleted for the full retention period. Plan for this in test environments where you repeatedly create and tear down resources with the same names.

4. **Replication latency varies.** Small test blobs typically replicate within 60 seconds, but larger datasets and cross-region distance can increase that. Monitor `ObjectReplicationSourceBytesReplicated` for throughput evidence.

5. **The AVM companion keeps replication activation separate for a reason.** Reviewing the deployment outputs before running `create-object-replication.sh` is the operational equivalent of a change-control gate. That split is even more valuable in the advanced path where CMK and private endpoints add complexity.

## Final take

The most useful infrastructure samples are not the ones that try to do everything. They are the ones that make the boundaries clear.

This companion track says:

- use **AVM/Bicep** for the repeatable storage foundation
- wire in **CMK**, **private endpoints**, and **monitoring** where those controls make sense
- keep the actual replication activation as an explicit operational step

That makes the repo more useful for architects and DevOps teams without diluting the original demo. One path remains optimized for learning and benchmarking. The new path is optimized for production-oriented implementation.
