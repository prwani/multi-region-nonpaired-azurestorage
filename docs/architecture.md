# Architecture — Multi-Region Non-Paired Azure Storage

## Overview

This project sets up **Azure Blob Storage Object Replication** between two non-paired Azure regions to demonstrate cross-region data replication without relying on GRS paired-region constraints.

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│  ┌─── Sweden Central (Source Region) ────────────────────────────────────────────────────┐   │
│  │                                                                                       │   │
│  │  ┌──────────────────────────────────────────────────────────────────────┐              │   │
│  │  │  Source Storage Account                                             │              │   │
│  │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐       │              │   │
│  │  │  │ source-01  │ │ source-02  │ │ source-03  │ │ source-NN  │ ...   │              │   │
│  │  │  └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘       │              │   │
│  │  │        │              │              │              │               │              │   │
│  │  │  ✔ Change feed enabled                                              │              │   │
│  │  │  ✔ Blob versioning enabled                                          │              │   │
│  │  └──────────────────────────┬───────────────────────────────────────────┘              │   │
│  │                             │                                                         │   │
│  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐                │   │
│  │    Benchmarking Only        │                                                         │   │
│  │  │                          ▲                                        │                │   │
│  │   ┌──────────────┐   Upload blobs                                                    │   │
│  │  ││ ACR          │──────────┘                                        │                │   │
│  │   │ (AzDataMaker │                                                                   │   │
│  │  ││  image)      │                                                   │                │   │
│  │   └──────┬───────┘                                                                   │   │
│  │  │       │ Pull image                                                │                │   │
│  │          ▼                                                                            │   │
│  │  │ ┌──────────────┐                                                  │                │   │
│  │   │ ACI           │   AzDataMaker instances                                          │   │
│  │  ││ (1..N)        │   generate test data                             │                │   │
│  │   └──────────────┘                                                                   │   │
│  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘                │   │
│  └───────────────────────────────────────────────────────────────────────────────────────┘   │
│                                            │                                                 │
│                                            │ Object Replication Policy                       │
│                                            │ (default or priority mode)                      │
│                                            │ Async cross-region replication                   │
│                                            ▼                                                 │
│  ┌─── Norway East (Destination Region) ──────────────────────────────────────────────────┐   │
│  │                                                                                       │   │
│  │  ┌──────────────────────────────────────────────────────────────────────┐              │   │
│  │  │  Destination Storage Account                                        │              │   │
│  │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐       │              │   │
│  │  │  │  dest-01   │ │  dest-02   │ │  dest-03   │ │  dest-NN   │ ...   │              │   │
│  │  │  └────────────┘ └────────────┘ └────────────┘ └────────────┘       │              │   │
│  │  │                                                                     │              │   │
│  │  │  ✔ Blob versioning enabled                                          │              │   │
│  │  └─────────────────────────────────────────────────────────────────────┘              │   │
│  └───────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Data Flow

### Production flow (solid components)

1. **Source Storage Account** in Sweden Central receives blob writes from applications
2. **Change feed** captures all write/delete operations on the source account
3. **Object Replication** reads the change feed and asynchronously replicates block blobs to the destination
4. **Destination Storage Account** in Norway East receives replicated blobs with metadata and properties intact
5. Each source container is paired with a destination container via a replication rule

### Benchmarking flow (dashed components)

1. **ACR** hosts the AzDataMaker container image (built from [Azure/azdatamaker](https://github.com/Azure/azdatamaker))
2. **ACI** instances pull the image and generate test data files
3. Files are uploaded to source containers in a round-robin pattern
4. This simulates real-world blob ingestion for performance measurement

## Replication Modes

| Mode | Description | SLA |
|------|-------------|-----|
| **Default** | Standard async replication, no guaranteed timeline | None |
| **Priority** | Prioritized replication with enhanced metrics | 99% within 15 min (same continent) |

## Prerequisites per Account

| Feature | Source Account | Destination Account |
|---------|---------------|-------------------- |
| Change feed | ✔ Required | Not needed |
| Blob versioning | ✔ Required | ✔ Required |
| StorageV2 or Premium Block Blob | ✔ Required | ✔ Required |
| Hierarchical namespace | ✖ Not supported | ✖ Not supported |

## Key Constraints

- Only **block blobs** are replicated (not append or page blobs)
- Destination containers become **read-only** while the replication policy is active
- A source account can replicate to at most **2 destination accounts**
- Priority replication can only be enabled on **1 policy per source account**
- Cross-tenant replication requires full resource IDs and `AllowCrossTenantReplication = true`

## Cross-Platform Support

All scripts are available in both **Bash** (`.sh`) and **PowerShell** (`.ps1`):

| Script | Bash | PowerShell |
|--------|------|-----------|
| Shared utilities | `common.sh` | `common.ps1` |
| Create storage | `01-create-storage.sh` | `01-create-storage.ps1` |
| Enable prerequisites | `02-enable-prereqs.sh` | `02-enable-prereqs.ps1` |
| Setup replication | `03-setup-replication.sh` | `03-setup-replication.ps1` |
| Ingest data (bench) | `bench-01-ingest-data.sh` | `bench-01-ingest-data.ps1` |
| Continue ingestion (bench) | `bench-02-continue-ingestion.sh` | `bench-02-continue-ingestion.ps1` |
| Monitor replication (bench) | `bench-03-monitor-replication.sh` | `bench-03-monitor-replication.ps1` |
| Run all | `setup-all.sh` | `setup-all.ps1` |
| Cleanup | `cleanup.sh` | `cleanup.ps1` |

Both versions use the same `config.env` file and support equivalent CLI parameters.
