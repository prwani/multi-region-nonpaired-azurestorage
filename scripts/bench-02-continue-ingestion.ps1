# ─────────────────────────────────────────────────────────────────────────────
# bench-02-continue-ingestion.ps1 — Continue data generation after replication
#
# BENCHMARKING ONLY — Generates additional data after replication is active
# to measure ongoing replication latency (vs historical catchup).
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
    Write-Host "Usage: bench-02-continue-ingestion.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Continue generating data after replication is active to measure ongoing latency."
    Write-Host "This is for benchmarking only — not part of production setup."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --data-size-gb <n>      Data to generate in this batch (default: 0.5)"
    Write-Host "  --aci-count <n>         Number of ACI instances (default: 1, AzDataMaker only)"
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
    $index = 0
    while ($index -lt $Arguments.Count) {
        switch ($Arguments[$index]) {
            '--use-azdatamaker' {
                $script:UseAzDataMaker = $true
            }
            '--data-size-gb' {
                $script:ContinueDataSizeExplicit = $true
                $remaining += $Arguments[$index]
                $remaining += $Arguments[$index + 1]
                $index++
            }
            default {
                $remaining += $Arguments[$index]
            }
        }
        $index++
    }

    $unknown = Parse-CommonArgs $remaining
    if ($unknown.Count -gt 0) {
        Write-Err "Unknown argument: $($unknown -join ', ')"
        usage
        exit 1
    }
}

function Invoke-AzDataMakerContinuation {
    [CmdletBinding()]
    param()

    $infrastructure = Initialize-AzDataMakerInfrastructure
    $containerNames = Get-ContainerNames -Prefix $script:SourceContainerPrefix
    $startIndex = Get-MaxAciIndex

    Write-Log "Deploying $($script:AciCount) additional ACI instance(s) for ongoing replication test..."
    $aciNames = @()
    for ($x = 1; $x -le $script:AciCount; $x++) {
        $aciName = Get-AciName -Index ($startIndex + $x)
        Deploy-AzDataMakerInstance `
            -AciName $aciName `
            -Infrastructure $infrastructure `
            -BlobContainers $containerNames `
            -ReportStatusIncrement 50
        $aciNames += $aciName
    }

    Wait-AciInstancesCompletion -AciNames $aciNames
}

$script:DataSizeGbFromEnvironment = -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable('DATA_SIZE_GB'))
$script:ContinueDataSizeExplicit = $false
$script:UseAzDataMaker = $UseAzDataMaker.IsPresent

Import-Config
Parse-BenchArgs $RemainingArgs
Set-AzSubscription

Test-RequiredTool 'az'

if ($env:CONTINUE_SIZE_GB) {
    $script:DataSizeGb = [double]$env:CONTINUE_SIZE_GB
}
elseif (-not $script:ContinueDataSizeExplicit -and -not $script:DataSizeGbFromEnvironment) {
    $script:DataSizeGb = 0.5
}

$startTime = Get-Date
$null = Get-AzDataMakerParams

if ($script:UseAzDataMaker) {
    Write-Log 'Using AzDataMaker (managed identity via ACR/ACI) for ongoing data generation...'
    Invoke-AzDataMakerContinuation
}
else {
    Write-Log 'Using local file generation + az CLI upload...'
    Invoke-LocalBlobUploadBenchmark `
        -FileNamePrefix 'continue' `
        -IntroMessage "Generating additional ~$($script:DataSizeGb) GB after replication is active..."
}

$elapsed = [int]((Get-Date) - $startTime).TotalSeconds

Write-Log 'Continued ingestion complete.'
Write-Ok  "Elapsed: ${elapsed}s"

# Calculate and report throughput
if ($elapsed -gt 0) {
    $avgFileMb = ($script:MaxFileSize + $script:MinFileSize) / 2
    $throughputMbs = [math]::Round($script:FileCount * $avgFileMb / $elapsed, 2)
    $throughputFps = [math]::Round($script:FileCount / $elapsed, 2)
    Write-Ok  "Throughput: ~${throughputMbs} MB/s (~${throughputFps} files/s)"
}

Write-Ok  "Additional data: ~$($script:DataSizeGb) GB"
Write-Log 'Run bench-03-monitor-replication.ps1 to measure replication latency.'
