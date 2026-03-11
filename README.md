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
- **jq** installed (for JSON processing)
- **bc** installed (for arithmetic in shell scripts)

## Quick Start

### Option A: 1-command setup (core + benchmarking)

```bash
# Edit config.env with your preferences, then:
./scripts/setup-all.sh
```

### Option B: Core setup only (production-like, no benchmarking)

```bash
./scripts/setup-all.sh --skip-benchmark
```

### Option C: Step-by-step

```bash
# 1. Create resource group + storage accounts
./scripts/01-create-storage.sh

# 2. Enable change feed, blob versioning, create source containers
./scripts/02-enable-prereqs.sh

# 3. (Benchmarking) Ingest test data BEFORE replication
./scripts/bench-01-ingest-data.sh

# 4. Set up object replication policy
./scripts/03-setup-replication.sh

# 5. (Benchmarking) Continue ingestion to test ongoing replication
./scripts/bench-02-continue-ingestion.sh

# 6. (Benchmarking) Monitor replication metrics
./scripts/bench-03-monitor-replication.sh
```

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

```bash
./scripts/01-create-storage.sh --source-region westeurope --dest-region uksouth
./scripts/bench-01-ingest-data.sh --data-size-gb 10 --aci-count 3
./scripts/03-setup-replication.sh --replication-mode priority
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

# Or via CLI
./scripts/03-setup-replication.sh --replication-mode priority
```

## Cleanup

```bash
./scripts/cleanup.sh        # Interactive confirmation
./scripts/cleanup.sh --yes  # Skip confirmation
./scripts/cleanup.sh --dry-run  # Preview
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
