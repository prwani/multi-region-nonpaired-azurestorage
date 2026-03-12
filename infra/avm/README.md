# AVM companion track

This folder adds a **production-oriented companion path** to the repo. The root scripts and [`README.md`](../../README.md) remain the fastest way to learn Azure Blob object replication, run benchmarks, and compare replication modes. This companion path is for teams that want a **repeatable AVM/Bicep foundation** they can adapt to a landing zone.

## When to use this track

Choose the **CLI-first main track** when you want:

- the fastest end-to-end learning experience
- local or AzDataMaker-based benchmarking
- a simple cross-platform walkthrough in Bash or PowerShell

Choose the **AVM companion track** when you want:

- storage accounts provisioned with Azure Verified Modules
- secure defaults closer to production expectations
- optional monitoring, CMK, and private endpoint integrations
- a clean split between infrastructure provisioning and replication activation

## What this track deploys

- two storage accounts provisioned with the **Azure Verified Module** for storage accounts
- source-side prerequisites for object replication: **change feed**, **blob versioning**, and source containers
- destination-side prerequisites: **blob versioning** and destination containers
- secure defaults such as **no blob public access**, **HTTPS only**, **TLS 1.2 minimum**, and **infrastructure encryption**
- optional **Log Analytics** integration for account metrics and blob-service diagnostics
- optional **customer-managed keys (CMK)** using an **existing** Key Vault key plus a user-assigned managed identity created by this template
- optional **storage private endpoints** wired to **existing** subnets and an existing `privatelink.blob.core.windows.net` private DNS zone

## What it intentionally does not deploy

- ACR, ACI, AzDataMaker, or any other benchmarking resources
- a full landing-zone implementation for networking, DNS, or centralized key management
- the object replication policy inside the Bicep template itself

That last point is deliberate. The storage foundation is well-suited to AVM/Bicep. The replication policy is treated as an explicit **post-deploy activation step** so teams can review the deployment and approve the moment when the destination side becomes read-only.

## Files in this folder

- `main.bicep` — companion infrastructure template
- `main.bicepparam` — baseline example with monitoring and secure defaults
- `advanced.bicepparam` — advanced example showing CMK + private endpoints wired to existing platform assets
- `create-object-replication.sh` — post-deploy activation for the object replication policy pair

## Prerequisites

- Azure CLI with Bicep support
- `jq` for `create-object-replication.sh`
- Contributor access to the target resource group
- If you plan to validate the deployment interactively after activation, blob data-plane permissions on the source and destination accounts are also recommended
- If `enableCmk=true`:
  - an **existing Key Vault key**
  - permission to create a role assignment for **Key Vault Crypto Service Encryption User** on that key
- If `enablePrivateEndpoints=true`:
  - existing private endpoint subnets in the source and destination regions
  - an existing `privatelink.blob.core.windows.net` private DNS zone

## Parameter files

### `main.bicepparam`

Use this for the baseline companion deployment. Update at least the storage account names before you deploy; they must be globally unique.

It keeps the companion opinionated but simple:

- `allowSharedKeyAccess = false`
- monitoring enabled
- no CMK
- no private endpoints

### `advanced.bicepparam`

Use this when you want to model a more enterprise-like posture. Replace all placeholder resource IDs and storage account names before deployment.

It shows how to wire in:

- an existing Log Analytics workspace
- an existing Key Vault key for CMK
- existing private endpoint subnets
- an existing `privatelink.blob.core.windows.net` private DNS zone

## Deploy the baseline companion path

```bash
az group create --name rg-objrepl-companion --location swedencentral

az deployment group create \
  --resource-group rg-objrepl-companion \
  --name avm-companion \
  --template-file infra/avm/main.bicep \
  --parameters infra/avm/main.bicepparam
```

The deployment outputs include the source and destination storage account names, resource IDs, and container pairs that the activation script uses later.

## Deploy the advanced companion path

After updating the placeholders in `advanced.bicepparam`, deploy it the same way:

```bash
az deployment group create \
  --resource-group rg-objrepl-companion \
  --name avm-companion-advanced \
  --template-file infra/avm/main.bicep \
  --parameters infra/avm/advanced.bicepparam
```

## Activate object replication after the Bicep deployment

The Bicep template provisions the storage foundation. Replication itself is activated in a second step:

```bash
./infra/avm/create-object-replication.sh \
  --resource-group rg-objrepl-companion \
  --deployment-name avm-companion
```

For priority replication:

```bash
./infra/avm/create-object-replication.sh \
  --resource-group rg-objrepl-companion \
  --deployment-name avm-companion \
  --replication-mode priority
```

The activation script:

1. reads the deployment outputs from `main.bicep`
2. creates the destination-side policy first
3. adds the remaining container rules to that policy
4. creates the matching source-side policy using the generated rule IDs

It uses `1601-01-01T00:00:00Z` by default so **existing and future blobs** replicate, matching the CLI demo behavior.

> **Operational note:** destination containers become **read-only** once the policy is active. That is why this step is intentionally separate from the Bicep deployment.

## Advanced scenario guidance

### CMK mode

CMK is intentionally modeled as an **integration with an existing platform Key Vault**, not as a new vault created in the same template. That keeps the companion path realistic for enterprise environments where key lifecycle, purge protection, rotation, and access governance are centrally owned.

When `enableCmk=true`, the template:

- creates a user-assigned managed identity
- grants it **Key Vault Crypto Service Encryption User** on the specified key
- configures both storage accounts to use that key for encryption at rest

Operationally, remember:

- key availability becomes part of your storage availability story
- key rotation should be tested in lower environments before production rollout
- if the Key Vault is later hardened with private access or firewall rules, validate storage access carefully afterward

### Private endpoint mode

Private endpoints are also modeled as **attachments to existing network assets**. That keeps the companion template small and leaves VNet, routing, and DNS ownership with the teams that usually own those controls.

When `enablePrivateEndpoints=true`, the template:

- creates a blob private endpoint for each storage account
- associates each endpoint with the provided private DNS zone
- sets storage firewall behavior to **deny by default** with `AzureServices` bypass enabled

This is a pragmatic middle ground for object replication: application traffic can stay on Private Link while Azure-managed replication and diagnostics still have a supported path. If your organization wants public network access fully disabled, validate replication, diagnostics, and operational tooling in that posture before standardizing it.

### Monitoring

Monitoring is enabled by default because production operators need evidence that replication is healthy. The template can either:

- create a small Log Analytics workspace in the same resource group, or
- target an existing shared workspace by ID

It sends:

- storage account metrics
- blob service logs and metrics

Alert rules are intentionally left to the landing zone or observability platform that owns your broader monitoring standard.

## Security and operations notes

- `allowSharedKeyAccess` defaults to `false`
- blob public access is disabled
- HTTPS only and minimum TLS 1.2 are enforced
- infrastructure encryption is enabled

This companion path does **not** provision the benchmark resources from the CLI demo, but it aligns well with the repo's updated security story: local benchmarking uses login-based uploads by default, and the optional AzDataMaker path uses managed identity.

Operationally:

- monitor `ObjectReplicationSourceBytesReplicated` and `ObjectReplicationSourceOperationsReplicated`
- in priority mode, also watch the pending backlog metrics by time bucket
- re-validate replication after CMK, DNS, firewall, or private endpoint changes
- remember that object replication is async and not a full application failover workflow by itself

## Related docs

- [`../../README.md`](../../README.md) — root overview and track selection
- [`../../Blog.md`](../../Blog.md) — CLI-first walkthrough for mixed audiences
- [`../../Blog2.md`](../../Blog2.md) — companion narrative and design trade-offs
- [`../../docs/architecture.md`](../../docs/architecture.md) — refreshed architecture and data flow
