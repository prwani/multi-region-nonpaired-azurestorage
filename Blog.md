# Cross-Region Blob Replication Without Paired Regions: A Practical Guide to Azure Object Replication

## Introduction

When you need your Azure Blob Storage data available in multiple regions — for disaster recovery, latency optimization, or compliance — Azure offers several options. The most common is **Geo-Redundant Storage (GRS)**, which automatically replicates data to a paired region. But what if the paired region doesn't meet your needs?

**Azure Object Replication** gives you the flexibility to replicate block blobs between *any* two Azure regions, on your terms. This guide walks you through setting it up between Sweden Central and Norway East (non-paired regions), generating test data, and measuring replication performance.

All scripts are provided in both **Bash** and **PowerShell**, so you can run them on **Windows, macOS, or Linux**.

---

## Why Object Replication?

### The Limitations of GRS and Paired Regions

Azure's GRS and RA-GRS (Read-Access Geo-Redundant Storage) are excellent for automatic geo-redundancy, but they come with constraints tied to the **paired region model**:

1. **No region choice** — GRS replicates only to Azure's pre-determined paired region. You cannot select a different destination. If Sweden Central is paired with Sweden South, that's your only option.

2. **Data residency concerns** — Your paired region may be in a different country or regulatory jurisdiction. For organizations bound by EU/EEA data residency requirements, this can be a blocker if the paired region falls outside compliant boundaries.

3. **Geographic distance** — Paired regions are chosen by Microsoft for maximum physical separation (for disaster resilience), which means higher latency for read access from the secondary.

4. **Limited service availability** — Some newer Azure regions have limited or no traditional pairing. Regions like Sweden South may have fewer services available, making the paired region less practical for active workloads.

5. **All-or-nothing replication** — GRS replicates the entire storage account. You can't selectively replicate specific containers or filter by blob prefix.

6. **No control over timing** — GRS replication is managed entirely by Azure with no SLA on replication lag (RPO is typically ~15 minutes but not guaranteed).

### What Object Replication Offers Instead

| Capability | GRS | Object Replication |
|-----------|-----|-------------------|
| Destination region | Fixed (paired only) | **Any region** |
| Granularity | Entire account | **Per-container, with prefix filters** |
| Data types | All blob types | Block blobs only |
| Cost model | Built into storage SKU (GRS/RA-GRS) | LRS + per-transaction + egress |
| Priority SLA | None | **99% within 15 min** (priority mode, same continent) |
| Cross-tenant | No | Yes (with configuration) |
| Multiple destinations | No | Up to 2 destination accounts |

Object Replication is ideal when you need:
- Replication to a **non-paired region** (compliance, latency, or preference)
- **Selective replication** (only certain containers or prefixes)
- **Cost control** (replicate only what matters, use LRS instead of GRS)
- **Measurable replication performance** (built-in metrics)

---

## Architecture

The following diagram shows all components in this demo. **Production components** (solid boxes) are what you'd use in a real deployment. **Benchmarking components** (dashed boxes) are only for performance testing.

```
┌─── Sweden Central ──────────────────────┐                    ┌─── Norway East ──────────────────────────┐
│                                          │                    │                                          │
│  ┌────────────────────────────────────┐  │   Object Repl.    │  ┌────────────────────────────────────┐  │
│  │  Source Storage Account            │  │  ═══════════════▶ │  │  Destination Storage Account       │  │
│  │                                    │  │  [default|priority]│  │                                    │  │
│  │  ┌──────────┐  ┌──────────┐       │  │                    │  │  ┌──────────┐  ┌──────────┐       │  │
│  │  │source-01 │  │source-02 │  ...  │  │                    │  │  │ dest-01  │  │ dest-02  │  ...  │  │
│  │  └──────────┘  └──────────┘       │  │                    │  │  └──────────┘  └──────────┘       │  │
│  │                                    │  │                    │  │                                    │  │
│  │  ✔ Change feed    ✔ Versioning    │  │                    │  │  ✔ Versioning                     │  │
│  └────────────────────────────────────┘  │                    │  └────────────────────────────────────┘  │
│           ▲                              │                    │                                          │
│           │                              │                    └──────────────────────────────────────────┘
│  ┌ ─ ─ ─ ┴ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  │
│    Benchmarking only                     │
│  │ ┌─────┐       ┌──────────────────┐│  │
│   │ ACR │──────▶│ ACI (AzDataMaker)│    │
│  │ └─────┘       │ generates test   ││  │
│                   │ data             │    │
│  │                └──────────────────┘│  │
│   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─   │
└──────────────────────────────────────────┘
```

---

## Prerequisites

- **Azure subscription** with Contributor access
- **Azure CLI** (`az`) — [Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- **PowerShell 7.0+** *(for PowerShell scripts)* — [Install guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) (cross-platform: Windows/macOS/Linux)
- **jq** — JSON processor ([install](https://jqlang.github.io/jq/download/)) *(Bash scripts only)*
- **bc** — Calculator (usually pre-installed on Linux/macOS) *(Bash scripts only)*

**Bash:**
```bash
az --version && jq --version && bc --version
az login
```

**PowerShell:**
```powershell
pwsh --version
az version
Connect-AzAccount  # or: az login
```

---

## Option A: 1-Command Setup

The fastest way to get everything running — infrastructure, test data, replication, and monitoring:

**Bash:**
```bash
git clone https://github.com/<your-org>/multi-region-nonpaired-azurestorage.git
cd multi-region-nonpaired-azurestorage

# (Optional) Edit config.env to customize regions, data size, etc.

./scripts/setup-all.sh
```

**PowerShell:**
```powershell
git clone https://github.com/<your-org>/multi-region-nonpaired-azurestorage.git
cd multi-region-nonpaired-azurestorage

./scripts/setup-all.ps1
```

This runs all steps in sequence:
1. Creates resource group + storage accounts
2. Enables change feed + blob versioning + creates containers
3. Ingests test data via AzDataMaker (benchmarking)
4. Sets up object replication policy
5. Continues ingestion to test ongoing replication
6. Monitors replication metrics

**Production-only setup** (no benchmarking):

**Bash:**
```bash
./scripts/setup-all.sh --skip-benchmark
```
**PowerShell:**
```powershell
./scripts/setup-all.ps1 -SkipBenchmark
```

**Custom data size and regions:**

**Bash:**
```bash
./scripts/setup-all.sh --data-size-gb 10 --source-region eastus --dest-region westus
```
**PowerShell:**
```powershell
./scripts/setup-all.ps1 -DataSizeGb 10 -SourceRegion eastus -DestRegion westus
```

---

## Option B: Step-by-Step Setup

### Step 1: Create Storage Accounts

**Bash:**
```bash
./scripts/01-create-storage.sh
```
**PowerShell:**
```powershell
./scripts/01-create-storage.ps1
```

This creates:
- A resource group in the source region
- A source storage account (StorageV2, Standard_LRS, Hot) in Sweden Central
- A destination storage account in Norway East

Both accounts use **Standard_LRS** (Locally Redundant Storage) — you don't need GRS because Object Replication handles the cross-region copy.

### Step 2: Enable Prerequisites

**Bash:**
```bash
./scripts/02-enable-prereqs.sh
```
**PowerShell:**
```powershell
./scripts/02-enable-prereqs.ps1
```

Object Replication requires:
- **Change feed** on the source account — captures blob write/delete events
- **Blob versioning** on both accounts — tracks blob versions for consistent replication

This script also creates the source blob containers (`source-01` through `source-05` by default).

### Step 3 (Benchmarking): Ingest Test Data

**Bash:**
```bash
./scripts/bench-01-ingest-data.sh
```
**PowerShell:**
```powershell
./scripts/bench-01-ingest-data.ps1
```

Before setting up replication, we ingest ~1 GB of test data to simulate a real-world scenario where data already exists. This lets us measure the **historical catchup** phase.

The script:
1. Creates an Azure Container Registry
2. Builds the [AzDataMaker](https://github.com/Azure/azdatamaker) container image
3. Deploys ACI instances to generate files into source containers

**Customize the data volume:**

**Bash:**
```bash
./scripts/bench-01-ingest-data.sh --data-size-gb 10
```
**PowerShell:**
```powershell
./scripts/bench-01-ingest-data.ps1 -DataSizeGb 10
```

### Step 4: Set Up Object Replication

**Bash:**
```bash
./scripts/03-setup-replication.sh
```
**PowerShell:**
```powershell
./scripts/03-setup-replication.ps1
```

This is the core step:
1. Creates destination containers (`dest-01` through `dest-05`)
2. Creates a replication policy on the destination account
3. Adds rules for each container pair (source-01 → dest-01, etc.)
4. Creates the matching policy on the source account

Since we set **copy scope = all objects**, the existing ~1 GB of data starts replicating immediately (historical catchup).

### Step 5 (Benchmarking): Continue Ingestion

**Bash:**
```bash
./scripts/bench-02-continue-ingestion.sh
```
**PowerShell:**
```powershell
./scripts/bench-02-continue-ingestion.ps1
```

After replication is active, this generates additional data to measure **ongoing replication latency** (as opposed to historical catchup).

### Step 6 (Benchmarking): Monitor Replication

**Bash:**
```bash
./scripts/bench-03-monitor-replication.sh
```
**PowerShell:**
```powershell
./scripts/bench-03-monitor-replication.ps1
```

This queries:
- **Blob-level replication status** — samples individual blobs for `complete`/`pending`/`failed`
- **Azure Monitor metrics** — bytes and operations replicated

---

## Default vs Priority Replication

Object Replication supports two modes, configurable via `REPLICATION_MODE` in `config.env` or `--replication-mode` CLI flag:

### Default Mode
- **Async replication** with no guaranteed timeline
- No additional per-GB cost beyond standard transactions and egress
- Suitable for cost-sensitive or non-critical workloads

### Priority Mode
- **99% of objects replicated within 15 minutes** (SLA, same continent)
- Automatically enables enhanced **OR metrics** (operations/bytes pending by time bucket)
- Per-GB ingress cost on replicated data
- Billing continues for **30 days after disabling**
- Only **1 priority policy per source account**

**SLA exclusions** (priority mode):
- Objects larger than 5 GB
- Objects modified more than 10 times per second
- Cross-continent source/destination pairs
- Accounts larger than 5 PB or with more than 10 billion blobs

**Bash:**
```bash
# Switch to priority mode
./scripts/03-setup-replication.sh --replication-mode priority

# Or in config.env
REPLICATION_MODE="priority"
```

**PowerShell:**
```powershell
./scripts/03-setup-replication.ps1 -ReplicationMode priority
```

---

## Performance Benchmarking Guide

### Choosing Your Data Volume

| Size | Use Case | Approx. Time (ingestion) |
|------|----------|-------------------------|
| 1 GB | Quick functional test | ~5 min |
| 10 GB | Moderate performance test | ~30 min |
| 50+ GB | Stress test / production simulation | ~2+ hours |

**Bash:**
```bash
# Adjust in config.env
DATA_SIZE_GB="10"

# Or via CLI
./scripts/bench-01-ingest-data.sh --data-size-gb 10 --aci-count 3
```

**PowerShell:**
```powershell
./scripts/bench-01-ingest-data.ps1 -DataSizeGb 10 -AciCount 3
```

### Measuring Historical Catchup

Historical catchup is the time taken to replicate pre-existing data after a replication policy is created.

1. Run `bench-01-ingest-data.sh` **before** `03-setup-replication.sh`
2. Note the timestamp when replication is configured
3. Run `bench-03-monitor-replication.sh` periodically until all blobs show `complete`
4. The difference is your historical catchup time

### Measuring Ongoing Replication Latency

1. Ensure replication is active (`03-setup-replication.sh` completed)
2. Run `bench-02-continue-ingestion.sh` to add new blobs
3. Immediately run `bench-03-monitor-replication.sh` to track how quickly new blobs replicate

### Comparing Default vs Priority

Run the full benchmark twice:
1. First with `REPLICATION_MODE="default"` — note catchup time and latency
2. Clean up, then re-run with `REPLICATION_MODE="priority"`
3. Compare results

### Key Metrics in Azure Portal

Navigate to **Storage Account → Monitoring → Metrics** and add:

| Metric | What It Shows |
|--------|--------------|
| `ObjectReplicationSourceBytesReplicated` | Total bytes replicated from source |
| `ObjectReplicationSourceOperationsReplicated` | Total operations replicated |
| Operations pending for replication *(priority only)* | Backlog by time bucket (0–5 min, 5–10 min, etc.) |
| Bytes pending for replication *(priority only)* | Data backlog by time bucket |

---

## Cleanup

Remove all resources when done:

**Bash:**
```bash
./scripts/cleanup.sh        # Interactive confirmation
./scripts/cleanup.sh --yes  # Skip confirmation
```

**PowerShell:**
```powershell
./scripts/cleanup.ps1       # Interactive confirmation
./scripts/cleanup.ps1 -Yes  # Skip confirmation
```

> **Important:** Run cleanup promptly after benchmarking to avoid ongoing charges.

---

## Cost Considerations

### Production Costs (Object Replication)

These costs apply to any production use of object replication:

| Component | Cost Driver | Notes |
|-----------|------------|-------|
| **Change feed** | Per-log-event charge | Charged on the source account for each operation captured |
| **Blob versioning** | Storage per version | Each version on source and destination counts as stored data |
| **Object replication** | Read transactions (source) + write transactions (destination) | Standard transaction rates apply |
| **Priority replication** | Per-GB ingress cost | Only if enabled; billing continues 30 days after disabling |
| **Storage accounts (×2)** | Standard LRS storage | Rates may differ between regions |
| **Data egress** | Cross-region bandwidth | Charged for data transferred from source to destination region |

### Benchmarking-Only Costs (Not in Production)

These resources are only needed for performance testing and should be deleted after benchmarking:

| Component | Cost Driver | Notes |
|-----------|------------|-------|
| **Azure Container Registry** | Standard SKU hosting + image storage | Delete via `cleanup.sh` when done |
| **Azure Container Instances** | Per-second vCPU + memory | Billed only while AzDataMaker runs |

> **Tip:** Run `./scripts/cleanup.sh` (or `./scripts/cleanup.ps1`) promptly after benchmarking. ACR and ACI are not needed beyond testing.

**Pricing references:**
- [Azure Storage Pricing](https://azure.microsoft.com/pricing/details/storage/)
- [Azure Bandwidth Pricing](https://azure.microsoft.com/pricing/details/bandwidth/)
- [Azure Container Registry Pricing](https://azure.microsoft.com/pricing/details/container-registry/)
- [Azure Container Instances Pricing](https://azure.microsoft.com/pricing/details/container-instances/)

---

## Conclusion & Next Steps

You've now set up **Azure Object Replication** between non-paired regions, generated test data, and measured replication performance. This approach gives you:

- **Region flexibility** — replicate to any region, not just paired ones
- **Granular control** — per-container rules with prefix filters
- **Measurable performance** — built-in metrics and optional SLA with priority mode
- **Cost optimization** — use LRS + selective replication instead of GRS

### Next Steps

- **Add prefix filters** to replication rules to selectively replicate specific blob paths
- **Configure lifecycle management** on the destination account to archive or delete old versions
- **Set up alerts** on replication lag metrics for proactive monitoring
- **Test failover** by pointing applications to the destination account
- **Explore priority replication** if you need guaranteed replication times

### References

- [Object Replication Overview](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-overview)
- [Configure Object Replication](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-configure)
- [Priority Replication](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-priority-replication)
- [AzDataMaker](https://github.com/Azure/azdatamaker)
