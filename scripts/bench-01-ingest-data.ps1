# ─────────────────────────────────────────────────────────────────────────────
# bench-01-ingest-data.ps1 — Generate test data and upload to source containers
#
# BENCHMARKING ONLY — Generates test data to measure replication performance.
#
# Uses local file generation + az CLI upload (--auth-mode login) by default.
# Pass -UseAzDataMaker (or --use-azdatamaker) to use AzDataMaker via ACR/ACI
# with managed identity instead.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [switch]$UseAzDataMaker,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArgs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

function usage {
    Write-Host "Usage: bench-01-ingest-data.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Generate test data and upload to source containers."
    Write-Host "This is for benchmarking only — not part of production setup."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --data-size-gb <n>      Total data to generate in GB (default: 1)"
    Write-Host "  --aci-count <n>         Number of ACI instances (default: 1, AzDataMaker only)"
    Write-Host "  --container-count <n>   Number of containers (default: 5)"
    Write-Host "  -UseAzDataMaker         Use AzDataMaker via ACR/ACI with managed identity"
    Write-Host "  --use-azdatamaker       Same as -UseAzDataMaker"
    Write-Host "  --subscription <id>     Azure subscription ID"
    Write-Host "  --dry-run               Preview without executing"
    Write-Host "  -h, --help              Show this help"
}

function Parse-BenchArgs {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $remaining = @()
    foreach ($argument in $Arguments) {
        if ($argument -eq '--use-azdatamaker') {
            $script:UseAzDataMaker = $true
            continue
        }
        $remaining += $argument
    }

    $unknown = Parse-CommonArgs $remaining
    if ($unknown.Count -gt 0) {
        Write-Err "Unknown argument: $($unknown -join ', ')"
        usage
        exit 1
    }
}

function Invoke-AzDataMakerIngestion {
    [CmdletBinding()]
    param()

    $infrastructure = Initialize-AzDataMakerInfrastructure
    $containerNames = Get-ContainerNames -Prefix $script:SourceContainerPrefix -Count $script:ContainerCount

    Write-Log "Deploying $($script:AciCount) ACI instance(s)..."
    $aciNames = @()
    for ($x = 1; $x -le $script:AciCount; $x++) {
        $aciName = Get-AciName -Index $x
        Deploy-AzDataMakerInstance `
            -AciName $aciName `
            -Infrastructure $infrastructure `
            -BlobContainers $containerNames `
            -ReportStatusIncrement 100 `
            -ReuseCompatible
        $aciNames += $aciName
    }

    Wait-AciInstancesCompletion -AciNames $aciNames
}

$script:UseAzDataMaker = $UseAzDataMaker.IsPresent

Import-Config
Parse-BenchArgs $RemainingArgs
Set-AzSubscription

Test-RequiredTool 'az'

$startTime = Get-Date
$null = Get-AzDataMakerParams

if ($script:UseAzDataMaker) {
    Write-Log 'Using AzDataMaker (managed identity via ACR/ACI) for data generation...'
    Invoke-AzDataMakerIngestion
}
else {
    Write-Log 'Using local file generation + az CLI upload...'
    Invoke-LocalBlobUploadBenchmark `
        -FileNamePrefix 'testfile' `
        -IntroMessage "Generating $($script:FileCount) test files locally..." `
        -ContainerNames (Get-ContainerNames -Prefix $script:SourceContainerPrefix -Count $script:ContainerCount)
}

$elapsed = [int]((Get-Date) - $startTime).TotalSeconds

Write-Log 'Data ingestion complete.'
Write-Ok  "Elapsed time: ${elapsed}s"

# Calculate and report throughput
if ($elapsed -gt 0) {
    $avgFileMb = ($script:MaxFileSize + $script:MinFileSize) / 2
    $throughputMbs = [math]::Round($script:FileCount * $avgFileMb / $elapsed, 2)
    $throughputFps = [math]::Round($script:FileCount / $elapsed, 2)
    Write-Ok  "Throughput: ~${throughputMbs} MB/s (~${throughputFps} files/s)"
}

Write-Ok  "Target data: ~$($script:DataSizeGb) GB across $($script:ContainerCount) container(s)"
