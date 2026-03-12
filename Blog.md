# Cross-Region Blob Replication Without Paired Regions: A Practical Guide to Azure Object Replication

When Azure's built-in paired-region model does not match your data residency, latency, or regional design requirements, **Azure Blob Object Replication** gives you a more deliberate option: replicate block blobs between storage accounts in the regions you choose.

This repo demonstrates that pattern with a **CLI-first main track** and a **production-oriented AVM companion track**. The main track is still the best way to learn the feature, run benchmarks, and see how replication behaves in practice. The companion track shows how to provision the storage foundation with AVM/Bicep and then activate replication as a separate operational step.

## Who this guide is for

| Audience | What to focus on |
|---|---|
| **Architects** | Region choice, data residency, security posture, selective replication, and the decision between the CLI demo and AVM companion |
| **Developers** | Fast setup, CLI examples, default local benchmarking, and how to measure historical catchup and ongoing replication |
| **DevOps / platform teams** | RBAC, monitoring, managed identity, read-only destination behavior, CMK/private endpoint options, and cutover caveats |

## Why object replication instead of GRS?

Azure GRS and RA-GRS are strong defaults when the paired region is acceptable and the platform-managed behavior is enough. They are weaker fits when you need to control **where** replicated data lives and **what** gets replicated.

| Question | GRS / RA-GRS | Object Replication |
|---|---|---|
| Destination region | Fixed Azure paired region | **Any supported region pair** |
| Scope | Whole account | **Per container, with optional prefix filters** |
| Data residency control | Limited | **High** |
| Benchmark visibility | Limited | **Better operational visibility through metrics and blob status** |
| Priority/SLA option | No | **Priority replication available for supported scenarios** |

Object replication is especially useful when you want to:

- keep data in a specific geography or compliance boundary
- replicate to a non-paired region for latency or operational reasons
- replicate only selected containers instead of an entire account
- measure replication throughput and backlog more directly

## Two tracks in this repo

| Track | What it is for | Main entry points |
|---|---|---|
| **CLI-first main track** | Learning, demos, hands-on setup, and benchmarking | [`README.md`](README.md), [`docs/architecture.md`](docs/architecture.md), `scripts/*.sh`, `scripts/*.ps1` |
| **AVM companion track** | Production-oriented provisioning baseline with optional monitoring, CMK, and private endpoints | [`infra/avm/README.md`](infra/avm/README.md), [`Blog2.md`](Blog2.md), `infra/avm/main.bicep` |

The most important point is simple: **the main repo is still CLI-first**. The AVM path complements it; it does not replace it.

## How the current implementation works

The working implementation in this repo now behaves as follows:

- the source and destination storage accounts are deployed in configurable non-paired regions (the sample defaults remain Sweden Central → Norway East)
- the source account has **change feed** and **blob versioning** enabled
- the destination account has **blob versioning** enabled
- source containers default to names such as `source-01`, `source-02`, and destination containers to `dest-01`, `dest-02`
- CLI storage account names come from `config.env`, and if you leave them blank the scripts derive stable names such as `objreplsrc736208` and `objrepldst736208` from the resource group name
- the AVM companion requires explicit storage account names in `.bicepparam` files instead of auto-generated names
- both Bash and PowerShell use the same replication pattern: create the first rule on the destination account, add the remaining rules there, then create the matching source-side policy

The repo also intentionally sets the copy scope to **all objects** by using:

```text
--min-creation-time '1601-01-01T00:00:00Z'
```

That matters because the Azure default is often misunderstood. If you leave copy-scope at the default behavior, only **new** objects replicate and historical data is skipped. This repo explicitly enables historical catchup so you can seed data first and then measure how quickly the backlog closes.

## Walkthrough: the CLI-first main track

If you want the fastest path to a working lab, start here.

### Fastest path: one command

**Bash**

```bash
./scripts/setup-all.sh
```

**PowerShell**

```powershell
./scripts/setup-all.ps1
```

To skip the benchmark pieces and focus on the replication configuration only:

**Bash**

```bash
./scripts/setup-all.sh --skip-benchmark
```

**PowerShell**

```powershell
./scripts/setup-all.ps1 -SkipBenchmark
```

### Step-by-step flow

| Step | Bash | PowerShell | What it does |
|---|---|---|---|
| 1 | `./scripts/01-create-storage.sh` | `./scripts/01-create-storage.ps1` | Creates the resource group and the two storage accounts |
| 2 | `./scripts/02-enable-prereqs.sh` | `./scripts/02-enable-prereqs.ps1` | Enables change feed/versioning and creates the source containers |
| 3 *(optional benchmark)* | `./scripts/bench-01-ingest-data.sh` | `./scripts/bench-01-ingest-data.ps1` | Seeds data before replication so you can measure historical catchup |
| 4 | `./scripts/03-setup-replication.sh` | `./scripts/03-setup-replication.ps1` | Creates destination containers and activates object replication |

> **Note:** Azure CLI limits individual `or-policy rule add` calls to 10 rules per policy. When you configure more than 10 container pairs, both the CLI demo scripts and the AVM companion activation script (`infra/avm/create-object-replication.sh`) automatically switch to a [JSON policy definition file](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-configure?tabs=azure-cli#configure-object-replication-using-a-json-file) that defines all rules in a single `or-policy create` call.
| 5 *(optional benchmark)* | `./scripts/bench-02-continue-ingestion.sh` | `./scripts/bench-02-continue-ingestion.ps1` | Adds new data after replication starts to measure ongoing latency |
| 6 *(optional benchmark)* | `./scripts/bench-03-monitor-replication.sh` | `./scripts/bench-03-monitor-replication.ps1` | Reads blob status and Azure Monitor metrics |

## Benchmarking: local first, AzDataMaker optional

One of the biggest documentation changes in the repo is the benchmarking story.

**Today, the default benchmark path in both Bash and PowerShell is local file generation plus `az storage blob upload --auth-mode login`.** That means the out-of-the-box path is simple:

- generate files locally on the operator workstation
- upload them with Azure CLI using the signed-in Azure identity
- watch object replication move them to the destination side

This is the fastest way to do a benchmark without also paying for or operating Azure Container Registry and Azure Container Instances.

### Optional AzDataMaker path

If you want scale-out data generation, the repo still supports AzDataMaker as an **optional** path:

- **Bash:** `--use-azdatamaker`
- **PowerShell:** `-UseAzDataMaker` or `--use-azdatamaker`

In the current implementation, that path:

- builds from [`https://github.com/Azure/AzDataMaker.git`](https://github.com/Azure/AzDataMaker.git)
- builds and stores the image in Azure Container Registry
- runs Azure Container Instances with a **system-assigned managed identity**
- passes `StorageAccountUri` into the container
- assigns **Storage Blob Data Contributor** on the **source storage account** to that managed identity

Shared key authentication is no longer the main story here. The two benchmark modes are now:

- **local + login auth** by default
- **AzDataMaker + managed identity** when explicitly requested

### What to measure

There are two useful benchmark patterns:

1. **Historical catchup** — run `bench-01-*` before replication is enabled, then activate replication and observe how long pre-existing data takes to complete.
2. **Ongoing replication latency** — enable replication first, then run `bench-02-*` and watch how quickly new blobs move.

The copy-all setting (`1601-01-01T00:00:00Z`) is what makes the first measurement possible.

## Security guidance

Security is where the demo and the companion track intentionally diverge.

### 1) Login-based authentication is the baseline

The interactive experience assumes you are signed in with Azure CLI:

```bash
az login
```

The local benchmark path, container creation, and blob inspection use Azure AD-backed data-plane access through commands such as `az storage blob upload --auth-mode login`. In other words, **shared key authentication is not the default story anymore**.

### 2) The interactive user needs both control-plane and data-plane access

The operator running the scripts typically needs:

- **Contributor or equivalent** on the target resource group or subscription so the scripts can create/update storage accounts, ACR, ACI, diagnostics, and replication policies
- a data-plane blob role on the source and destination accounts or their containers so the scripts can create containers, upload data, list blobs, and inspect replication status

The simplest documented baseline is **Storage Blob Data Contributor** on both storage accounts for the interactive user. You can narrow that model if your organization prefers split duties, but whatever principal runs the scripts still needs the permissions required by the steps you actually execute.

### 3) The AzDataMaker path uses managed identity

When you opt into AzDataMaker, the benchmark automation identity is not your user account. Each ACI instance gets a **system-assigned managed identity**, receives `StorageAccountUri`, and is granted **Storage Blob Data Contributor** on the **source** storage account. That is a cleaner benchmark story than relying on shared keys or embedding credentials in containers.

### 4) Benchmarking posture and production posture are different by design

The CLI-first track is optimized for understanding the feature, iterating quickly, and measuring behavior. The AVM companion is optimized for a harder production baseline. In the AVM path:

- `allowSharedKeyAccess` defaults to `false`
- blob public access is disabled
- HTTPS-only and minimum TLS 1.2 are enforced
- infrastructure encryption is enabled
- monitoring is built in, and CMK/private endpoints are optional integrations

That split is healthy. A benchmark lab and a production landing zone should not have identical priorities.

## Operations guidance

Replication is only useful if operations teams can prove it is healthy and understand its limits.

### Metrics to monitor

| Signal | Why to watch it |
|---|---|
| `ObjectReplicationSourceBytesReplicated` | Baseline evidence that bytes are moving |
| `ObjectReplicationSourceOperationsReplicated` | Confirms replicated operations and helps compare throughput across tests |
| `Operations pending for replication` *(priority mode)* | Backlog signal for SLA-sensitive workloads |
| `Bytes pending for replication` *(priority mode)* | Data backlog by age bucket in priority mode |
| Blob `replicationStatus` samples (`complete`, `pending`, `failed`) | Useful per-object spot checks during validation or incident response |
| Storage account metrics and blob service logs | Useful for access, network, and post-change validation, especially in the AVM path |

### Read-only destination behavior

This is the operational caveat people forget most often: **destination containers become read-only once object replication is active**. That is why the AVM companion deliberately separates provisioning from activation. It lets teams review the deployment before making the destination part of a live replication topology.

### Troubleshooting guide

If replication does not behave as expected, check these first:

- **Historical data not replicating?** Confirm the policy was created with the copy-all behavior (`--min-creation-time '1601-01-01T00:00:00Z'`).
- **Uploads or blob inspection failing?** Check Azure AD login state, data-plane RBAC, and any storage firewall or private access restrictions.
- **Replication policy issues?** Verify change feed is enabled on the source and versioning is enabled on both accounts.
- **AzDataMaker issues?** Check the ACR build, ACI lifecycle state, managed identity assignment, `StorageAccountUri`, and the source-account role assignment.
- **Post-hardening regressions?** After CMK, private endpoint, DNS, or firewall changes, re-test replication and diagnostics explicitly.

### Failover and cutover caveats

Object replication supports regional resilience, but it does **not** deliver a turnkey application failover workflow on its own.

It does not automatically:

- switch application endpoints or DNS
- move your application secrets or identities
- make the destination writeable while the policy remains active
- provide a full failback workflow after a cutover

Treat object replication as one building block inside a broader DR or cutover plan, not the entire runbook.

## Cost guidance

There are two different cost stories in this repo.

### Production-style object replication costs

These are relevant regardless of whether you use the CLI track or the AVM track:

- change feed costs on the source account
- blob versioning storage on both sides
- source-side reads and destination-side writes for replicated traffic
- cross-region data transfer costs
- **priority replication** charges when enabled

Priority replication deserves special care because the cost is not just “faster mode.” It adds a per-GB cost and the billing impact continues for **30 days after disabling**.

### Benchmark-only costs

The current default benchmark path is cheaper because it stays local and uses your CLI session. You only incur the Azure Storage costs associated with the objects you upload.

The **optional** AzDataMaker path adds:

- Azure Container Registry cost
- Azure Container Instances cost

That makes the local default path the better starting point for quick validation, while AzDataMaker is the right choice when you need scale or parallelism.

## When to use the AVM companion track

Use the AVM companion when the conversation changes from “show me the feature” to “show me a production-oriented baseline.”

The companion path:

- provisions the storage foundation with `infra/avm/main.bicep`
- supports optional monitoring, CMK, and private endpoints
- keeps replication activation as a separate CLI step with `infra/avm/create-object-replication.sh`

Start with:

- [`infra/avm/README.md`](infra/avm/README.md) for deployment commands and parameter-file guidance
- [`Blog2.md`](Blog2.md) for the architectural rationale and design trade-offs

## Final take

Azure Object Replication is the right tool when you need more control than paired-region GRS can provide. This repo now presents that story in two useful ways:

- a **CLI-first main track** that is easy to learn, easy to benchmark, and honest about how replication behaves
- an **AVM companion track** that shows how to provision a more production-oriented storage baseline and then activate replication deliberately

For architects, that means better control over region design and security boundaries. For developers, it means a simple path to reproduce and measure behavior. For DevOps teams, it means clearer RBAC, monitoring, and operational boundaries.
