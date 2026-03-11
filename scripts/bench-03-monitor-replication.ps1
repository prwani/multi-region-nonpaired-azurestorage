# ─────────────────────────────────────────────────────────────────────────────
# bench-03-monitor-replication.ps1 — Monitor replication status and latency
#
# BENCHMARKING ONLY — Uses Azure Monitor metrics and blob replication status
# headers to measure historical catchup and ongoing replication performance.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

function usage {
    Write-Host "Usage: bench-03-monitor-replication.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Monitor object replication metrics and blob-level replication status."
    Write-Host "This is for benchmarking only."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --subscription <id>    Azure subscription ID"
    Write-Host "  --dry-run              Preview without executing"
    Write-Host "  -h, --help             Show this help"
}

function Check-BlobReplicationStatus {
    <#
    .SYNOPSIS
        BENCHMARKING ONLY — Samples blobs in a container and reports replication status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Container,
        [int]$SampleCount = 5
    )

    Write-Log "Checking replication status for blobs in '$Container'..."
    try {
        $blobs = az storage blob list `
            --account-name $Account `
            --auth-mode login `
            --container-name $Container `
            --num-results $SampleCount `
            --query "[].name" -o tsv 2>$null
    } catch {
        $blobs = $null
    }

    if ([string]::IsNullOrWhiteSpace($blobs)) {
        Write-Warn "No blobs found in '$Container'"
        return
    }

    $total     = 0
    $completed = 0
    $pending   = 0
    $failed    = 0

    foreach ($blob in ($blobs -split "`n")) {
        $blob = $blob.Trim()
        if ([string]::IsNullOrWhiteSpace($blob)) { continue }
        $total++
        try {
            $status = az storage blob show `
                --account-name $Account `
                --auth-mode login `
                --container-name $Container `
                --name $blob `
                --query "properties.replicationStatus" -o tsv 2>$null
        } catch {
            $status = 'unknown'
        }
        switch ($status) {
            'complete' { $completed++ }
            'pending'  { $pending++ }
            'failed'   { $failed++ }
        }
    }

    Write-Host "  ┌─────────────────────────────────────"
    Write-Host "  │ Container: $Container"
    Write-Host "  │ Sampled:   $total blobs"
    Write-Host "  │ Completed: $completed"
    Write-Host "  │ Pending:   $pending"
    Write-Host "  │ Failed:    $failed"
    Write-Host "  └─────────────────────────────────────"
}

function Query-ReplicationMetrics {
    <#
    .SYNOPSIS
        BENCHMARKING ONLY — Queries Azure Monitor for a replication metric.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][string]$Metric,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $endTime   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $startTime = (Get-Date).AddHours(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    try {
        $result = az monitor metrics list `
            --resource $AccountId `
            --metric $Metric `
            --start-time $startTime `
            --end-time $endTime `
            --interval PT5M `
            --aggregation Total `
            --query "value[0].timeseries[0].data[-1].total" `
            -o tsv 2>$null
    } catch {
        $result = 'N/A'
    }
    if ([string]::IsNullOrWhiteSpace($result)) { $result = 'N/A' }

    Write-Host "  │ ${DisplayName}: $result"
}

Import-Config
Parse-CommonArgs $args
Set-AzSubscription

Test-RequiredTool 'az'

# ── Get account info (BENCHMARKING ONLY) ─────────
$srcId = az storage account show `
    --name $script:SourceStorage `
    --resource-group $script:ResourceGroup `
    --query "id" -o tsv

# ── Check blob-level replication status ──────────
Write-Log "═══ Blob Replication Status (sampled) ═══"
$width = ([string]$script:ContainerCount).Length
for ($i = 1; $i -le $script:ContainerCount; $i++) {
    $cname = "$($script:SourceContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
    Check-BlobReplicationStatus -Account $script:SourceStorage -Container $cname -SampleCount 5
}

# ── Query Azure Monitor metrics ──────────────────
Write-Log "═══ Azure Monitor Replication Metrics (last hour) ═══"
Write-Host "  ┌─────────────────────────────────────"
Query-ReplicationMetrics -AccountId $srcId -Metric 'ObjectReplicationSourceBytesReplicated'      -DisplayName 'Bytes replicated'
Query-ReplicationMetrics -AccountId $srcId -Metric 'ObjectReplicationSourceOperationsReplicated'  -DisplayName 'Operations replicated'
Write-Host "  └─────────────────────────────────────"

# ── Summary ──────────────────────────────────────
Write-Log "═══ Summary ═══"
Write-Ok  "Source account:  $($script:SourceStorage) ($($script:SourceRegion))"
Write-Ok  "Dest account:    $($script:DestStorage) ($($script:DestRegion))"
Write-Ok  "Replication mode: $($script:ReplicationMode)"
Write-Ok  "Containers:      $($script:ContainerCount)"
Write-Host ''
Write-Log "For detailed metrics, visit Azure Portal → Storage Account → Monitoring → Metrics"
Write-Log "Key metrics to track:"
Write-Host "  • ObjectReplicationSourceBytesReplicated"
Write-Host "  • ObjectReplicationSourceOperationsReplicated"
if ($script:ReplicationMode -eq 'priority') {
    Write-Host "  • Operations pending for replication (by time bucket)"
    Write-Host "  • Bytes pending for replication (by time bucket)"
}
