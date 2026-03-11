# Multi-Region Non-Paired Azure Storage — Object Replication Demo

> Demonstrates **Azure Blob Storage Object Replication** between non-paired regions (Sweden Central → Norway East) with configurable data generation and performance benchmarking.

## Why This Repo?

Azure's built-in **GRS (Geo-Redundant Storage)** only replicates to a fixed paired region. **Object Replication** lets you replicate block blobs to **any** region — giving you control over data residency, latency optimization, and cost management.

This repo provides:
- **Production-ready scripts** to set up object replication between any two Azure regions
- **Benchmarking tools** (using [AzDataMaker](https://github.com/Azure/azdatamaker)) to measure replication performance
- **A publishable blog post** (`Blog.md`) with full walkthrough

## Architecture

```
┌─────────────────────────────┐         Object Replication         ┌─────────────────────────────┐
│   Sweden Central (Source)   │  ─────────────────────────────────▶ │   Norway East (Destination) │
│                             │    default or priority mode         │                             │
│  ┌─────────────────────┐    │                                    │  ┌─────────────────────┐    │
│  │ source-01           │────│────────────────────────────────────▶│──│ dest-01             │    │
│  │ source-02           │────│────────────────────────────────────▶│──│ dest-02             │    │
│  │ source-03           │────│────────────────────────────────────▶│──│ dest-03             │    │
│  │ source-04           │────│────────────────────────────────────▶│──│ dest-04             │    │
│  │ source-05           │────│────────────────────────────────────▶│──│ dest-05             │    │
│  └─────────────────────┘    │                                    │  └─────────────────────┘    │
│                             │                                    │                             │
│  ✔ Change feed enabled      │                                    │  ✔ Blob versioning enabled  │
│  ✔ Blob versioning enabled  │                                    │                             │
└─────────────────────────────┘                                    └─────────────────────────────┘
         ▲
         │ (benchmarking only)
    ┌────┴────┐
    │  ACI    │  AzDataMaker
    │ (ACI)   │  instances
    └────┬────┘
         │
    ┌────┴────┐
    │  ACR    │  Container
    │         │  Registry
    └─────────┘
```

## Prerequisites

- **Azure subscription** with Contributor access
- **Azure CLI** installed and logged in (`az login`)
- **PowerShell 7.0+** *or* **Bash 4+** — all scripts ship in both `.sh` and `.ps1` variants
- **jq** / **bc** (Bash only — PowerShell scripts use built-in JSON and math)

> Scripts work on **Windows, macOS, and Linux**. Use whichever shell you prefer.

## Quick Start

### Option A: 1-command setup (core + benchmarking)

**Bash:**
```bash
./scripts/setup-all.sh
```

**PowerShell:**
```powershell
./scripts/setup-all.ps1
```

### Option B: Core setup only (production-like, no benchmarking)

**Bash:**
```bash
./scripts/setup-all.sh --skip-benchmark
```

**PowerShell:**
```powershell
./scripts/setup-all.ps1 -SkipBenchmark
```

### Option C: Step-by-step

| Step | Bash | PowerShell |
|------|------|------------|
| 1. Create resource group + storage | `./scripts/01-create-storage.sh` | `./scripts/01-create-storage.ps1` |
| 2. Enable change feed, versioning, containers | `./scripts/02-enable-prereqs.sh` | `./scripts/02-enable-prereqs.ps1` |
| 3. *(Bench)* Ingest test data before replication | `./scripts/bench-01-ingest-data.sh` | `./scripts/bench-01-ingest-data.ps1` |
| 4. Set up object replication policy | `./scripts/03-setup-replication.sh` | `./scripts/03-setup-replication.ps1` |

> **⚠️ Copy Scope:** By default, object replication only copies **new blobs** — pre-existing data is skipped. Our scripts set `--min-creation-time '1601-01-01T00:00:00Z'` to replicate all existing and future objects. If configuring manually, set the copy scope to "Copy all objects".
| 5. *(Bench)* Continue ingestion | `./scripts/bench-02-continue-ingestion.sh` | `./scripts/bench-02-continue-ingestion.ps1` |
| 6. *(Bench)* Monitor replication metrics | `./scripts/bench-03-monitor-replication.sh` | `./scripts/bench-03-monitor-replication.ps1` |

## Configuration

All settings live in **one file**: [`config.env`](config.env). Override via CLI flags on any script.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SOURCE_REGION` | `swedencentral` | Source storage account region |
| `DEST_REGION` | `norwayeast` | Destination region (non-paired) |
| `RESOURCE_GROUP` | `rg-objrepl-demo` | Resource group name |
| `CONTAINER_COUNT` | `5` | Number of blob containers |
| `REPLICATION_MODE` | `default` | `default` or `priority` |
| `DATA_SIZE_GB` | `1` | Total test data volume (benchmarking) |
| `ACI_COUNT` | `1` | ACI instances for data generation |

**CLI override examples:**

**Bash:**
```bash
./scripts/01-create-storage.sh --source-region westeurope --dest-region uksouth
./scripts/bench-01-ingest-data.sh --data-size-gb 10 --aci-count 3
./scripts/03-setup-replication.sh --replication-mode priority
```

**PowerShell:**
```powershell
./scripts/01-create-storage.ps1 -SourceRegion westeurope -DestRegion uksouth
./scripts/bench-01-ingest-data.ps1 -DataSizeGb 10 -AciCount 3
./scripts/03-setup-replication.ps1 -ReplicationMode priority
```

**Precedence:** CLI flags > environment variables > config.env > built-in defaults

## Replication Modes

| Mode | SLA | Extra Cost | Best For |
|------|-----|-----------|----------|
| **default** | None (async, best-effort) | No per-GB cost | Cost-sensitive workloads |
| **priority** | 99% within 15 min (same continent) | Per-GB ingress cost | DR, business continuity |

Switch modes:
```bash
# In config.env
REPLICATION_MODE="priority"

# Or via CLI (Bash / PowerShell)
./scripts/03-setup-replication.sh  --replication-mode priority
./scripts/03-setup-replication.ps1 -ReplicationMode priority
```

## Cleanup

**Bash:**
```bash
./scripts/cleanup.sh              # Interactive confirmation
./scripts/cleanup.sh --yes        # Skip confirmation
./scripts/cleanup.sh --dry-run    # Preview
```

**PowerShell:**
```powershell
./scripts/cleanup.ps1             # Interactive confirmation
./scripts/cleanup.ps1 -Yes        # Skip confirmation
./scripts/cleanup.ps1 -DryRun     # Preview
```

## Repo Structure

```
scripts/
  setup-all.{sh,ps1}                # Full setup (core + optional benchmarking)
  01-create-storage.{sh,ps1}        # Resource group + storage accounts
  02-enable-prereqs.{sh,ps1}        # Change feed, versioning, containers
  03-setup-replication.{sh,ps1}     # Object replication policy
  bench-01-ingest-data.{sh,ps1}     # Generate test blobs via ACI
  bench-02-continue-ingestion.{sh,ps1}
  bench-03-monitor-replication.{sh,ps1}
  cleanup.{sh,ps1}                  # Tear down all resources
config.env                          # Shared configuration (both shells)
Blog.md                             # Publishable walkthrough
```

## Blog Post

See [`Blog.md`](Blog.md) for a complete, publishable walkthrough covering:
- Why object replication over GRS
- Step-by-step setup guide
- Performance benchmarking methodology
- Cost considerations

## References

- [Object Replication Overview](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-overview)
- [Configure Object Replication](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-configure)
- [Priority Replication](https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-priority-replication)
- [AzDataMaker](https://github.com/Azure/azdatamaker)
- [Azure Storage Pricing](https://azure.microsoft.com/pricing/details/storage/)

## License

MIT
