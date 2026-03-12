# Multi-Region Non-Paired Azure Storage — Object Replication Demo

> Demonstrates Azure Blob Storage Object Replication between non-paired regions, with a **CLI-first demo track** for learning and benchmarking plus an **AVM/Bicep companion track** for production-oriented provisioning.

## Overview

- The **main repo remains CLI-first**: Bash and PowerShell scripts walk through storage creation, prerequisite configuration, replication setup, benchmarking, and cleanup.
- **Benchmarking now defaults to local file generation plus `az storage blob upload --auth-mode login`** in both Bash and PowerShell.
- The **optional AzDataMaker benchmarking path** is available as `--use-azdatamaker` (Bash) and `-UseAzDataMaker` or `--use-azdatamaker` (PowerShell).
- The **AVM companion track** lives under [`infra/avm/`](infra/avm/) with supporting narrative in [`Blog2.md`](Blog2.md).
- Bash and PowerShell now have **replication parity**: both create the first rule on the destination account, add remaining container pairs, and then create the matching source-side policy.

## Choose your track

| Track | Use it when | Start here | Activation model |
|---|---|---|---|
| **CLI-first demo** | You want the fastest learning path, a reproducible benchmark, or a simple end-to-end feature walkthrough | This README, [`Blog.md`](Blog.md), [`docs/architecture.md`](docs/architecture.md) | Scripts provision the accounts and activate replication |
| **AVM companion** | You want an AVM/Bicep foundation, secure defaults, optional monitoring/CMK/private endpoints, and clearer change control before enabling replication | [`infra/avm/README.md`](infra/avm/README.md), [`Blog2.md`](Blog2.md) | `main.bicep` provisions the foundation; `infra/avm/create-object-replication.sh` activates replication |

## Track 1: CLI-first quick start

All core settings live in [`config.env`](config.env). You can keep the defaults, edit the file, or override values with CLI flags.

### One-command path

**Bash**

```bash
./scripts/setup-all.sh
```

**PowerShell**

```powershell
./scripts/setup-all.ps1
```

### Core setup only (no benchmarking)

**Bash**

```bash
./scripts/setup-all.sh --skip-benchmark
```

**PowerShell**

```powershell
./scripts/setup-all.ps1 -SkipBenchmark
```

### Step-by-step flow

| Step | Bash | PowerShell |
|---|---|---|
| Create resource group and storage accounts | `./scripts/01-create-storage.sh` | `./scripts/01-create-storage.ps1` |
| Enable change feed, versioning, and source containers | `./scripts/02-enable-prereqs.sh` | `./scripts/02-enable-prereqs.ps1` |
| *(Optional benchmark)* Seed data before replication | `./scripts/bench-01-ingest-data.sh` | `./scripts/bench-01-ingest-data.ps1` |
| Activate object replication | `./scripts/03-setup-replication.sh` | `./scripts/03-setup-replication.ps1` |
| *(Optional benchmark)* Continue ingestion after replication starts | `./scripts/bench-02-continue-ingestion.sh` | `./scripts/bench-02-continue-ingestion.ps1` |
| *(Optional benchmark)* Monitor replication health and throughput | `./scripts/bench-03-monitor-replication.sh` | `./scripts/bench-03-monitor-replication.ps1` |

### Naming behavior to expect

- Storage account names come from `SOURCE_STORAGE` and `DEST_STORAGE` in `config.env`.
- If those values are blank, the CLI scripts derive stable names from the resource group hash, for example `objreplsrc736208` and `objrepldst736208`.
- Container pairs default to `source-01` → `dest-01`, `source-02` → `dest-02`, and so on.
- The AVM companion is different: its `.bicepparam` files require **explicit storage account names**.

## Track 2: AVM companion quick start

The companion track is for teams that want AVM/Bicep to provision the storage foundation, then a separate activation step to turn on object replication.

1. Review and update [`infra/avm/main.bicepparam`](infra/avm/main.bicepparam) or [`infra/avm/advanced.bicepparam`](infra/avm/advanced.bicepparam). The storage account names must be globally unique.
2. Deploy the Bicep foundation:

```bash
az group create --name rg-objrepl-companion --location swedencentral

az deployment group create \
  --resource-group rg-objrepl-companion \
  --name avm-companion \
  --template-file infra/avm/main.bicep \
  --parameters infra/avm/main.bicepparam
```

3. Activate replication after the deployment completes:

```bash
./infra/avm/create-object-replication.sh \
  --resource-group rg-objrepl-companion \
  --deployment-name avm-companion
```

For the production-oriented walkthrough and trade-offs, see [`Blog2.md`](Blog2.md). For full deployment instructions, advanced parameter guidance, and post-deploy activation details, see [`infra/avm/README.md`](infra/avm/README.md).

## Benchmarking modes

| Mode | How it works today | Best for |
|---|---|---|
| **Default local path** | Both Bash and PowerShell generate files locally and upload them with `az storage blob upload --auth-mode login` | Quick functional tests, smaller benchmarks, and environments where you want the simplest path and no ACR/ACI cost |
| **Optional AzDataMaker path** | Bash: `--use-azdatamaker`<br>PowerShell: `-UseAzDataMaker` or `--use-azdatamaker` | Larger or parallelized test-data generation |

The optional AzDataMaker path currently:

- builds from [`https://github.com/Azure/AzDataMaker.git`](https://github.com/Azure/AzDataMaker.git)
- pushes the image to Azure Container Registry
- runs Azure Container Instances with a **system-assigned managed identity**
- passes `StorageAccountUri` to the container
- assigns **Storage Blob Data Contributor** on the **source storage account** to that managed identity

Shared key authentication is **no longer the main story** in this repo. The default benchmark path uses your interactive Azure login, and the optional AzDataMaker path uses managed identity.

## Security guidance

- Run the repo with an authenticated Azure identity (`az login`). The local benchmark path, container creation, and blob inspection all use **login-based** data-plane access.
- The interactive user should have management-plane rights to create or update the resource group, storage accounts, ACR/ACI resources, and replication policy. **Contributor or equivalent** is the simplest documented setup.
- Because the scripts use Azure AD for data-plane operations, the same user should also have a blob data role on the source and destination accounts or their containers. **Storage Blob Data Contributor** on both accounts is the easiest baseline; equivalent narrower roles are fine if they still allow container creation, upload, list, and blob inspection.
- The optional AzDataMaker path uses a **system-assigned managed identity** on each ACI instance plus a **Storage Blob Data Contributor** assignment on the source account. That is the benchmark automation identity; it is separate from the interactive user.
- For production-oriented deployments, prefer the AVM companion. It defaults to `allowSharedKeyAccess=false`, disables blob public access, enforces HTTPS and minimum TLS 1.2, and supports optional monitoring, CMK, and private endpoints.

## Operations guidance

### Metrics and signals to monitor

| Signal | Why it matters |
|---|---|
| `ObjectReplicationSourceBytesReplicated` | Confirms bytes are actually flowing from source to destination |
| `ObjectReplicationSourceOperationsReplicated` | Shows replicated write activity and helps validate throughput |
| Priority-only pending metrics (`Operations pending for replication`, `Bytes pending for replication`) | Shows backlog by time bucket and helps detect SLA risk in priority mode |
| Blob `replicationStatus` samples | Useful spot-check for `complete`, `pending`, or `failed` blobs |
| Blob service logs and storage metrics | Helpful for troubleshooting access, network, or policy issues, especially in the AVM companion path |

### Operational caveats

- Destination containers become **read-only once object replication is active**. Complete any seeding, review, or approval steps before enabling the policy.
- The scripts intentionally use `--min-creation-time '1601-01-01T00:00:00Z'` so **existing and future blobs** are replicated. If you create policies some other way and keep the default copy-scope, pre-existing data will not backfill.
- If replication or uploads fail, first check: change feed on the source account, blob versioning on both accounts, data-plane RBAC for the interactive user, and any storage network restrictions that might block your client or operators.
- If the optional AzDataMaker path fails, check the ACR build, ACI instance state and logs, managed identity assignment, and the `StorageAccountUri`/role assignment on the source account.
- If you use the AVM companion with CMK or private endpoints, re-validate replication and diagnostics after any key, firewall, DNS, or network change.

### Failover and cutover caveats

Object replication is valuable for regional resilience, but it is **not a full failover product by itself**. It does not automatically switch application endpoints, secrets, identities, DNS, or application permissions for you. Plan and test cutover and failback runbooks separately, and remember that the destination side is read-only while the policy remains active.

## Related docs

- [`Blog.md`](Blog.md) — publishable walkthrough for architects, developers, and DevOps readers
- [`Blog2.md`](Blog2.md) — AVM companion narrative and design trade-offs
- [`docs/architecture.md`](docs/architecture.md) — refreshed architecture and data-flow reference
- [`infra/avm/README.md`](infra/avm/README.md) — AVM deployment instructions and post-deploy activation flow

## References

- [Azure Blob Object Replication overview](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-overview)
- [Configure Azure Blob Object Replication](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-configure)
- [Priority replication](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-priority-replication)
- [Optional AzDataMaker source used by this repo](https://github.com/Azure/AzDataMaker.git)
- [Azure Storage pricing](https://azure.microsoft.com/pricing/details/storage/)

## License

MIT
