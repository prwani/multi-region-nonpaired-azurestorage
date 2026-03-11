# ─────────────────────────────────────────────────────────────────────────────
# setup-all.ps1 — 1-command orchestrator
#
# Runs core setup and (optionally) benchmarking scripts sequentially.
# Use -SkipBenchmark to run only the production-relevant core setup.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [switch]$SkipBenchmark,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArgs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

function usage {
    Write-Host "Usage: setup-all.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Run all setup steps in sequence. Supports all config.env overrides."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -SkipBenchmark         Run only core setup (no AzDataMaker/ACI)"
    Write-Host "  -DryRun                Preview without executing"
    Write-Host "  --subscription <id>    Azure subscription ID"
    Write-Host "  -h, --help             Show this help"
    Write-Host ""
    Write-Host "All config.env parameters can be overridden via CLI flags."
    Write-Host "Example: setup-all.ps1 --data-size-gb 10 --source-region eastus -DryRun"
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Description,
        [string[]]$ForwardArgs = @()
    )

    Write-Host ""
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Log $Description
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    $stepStart = Get-Date
    & "$ScriptDir/$Script" @ForwardArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Err "$Description — failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    $stepElapsed = [int](New-TimeSpan -Start $stepStart -End (Get-Date)).TotalSeconds

    Write-Ok "$Description — completed in ${stepElapsed}s"
    $script:StepTimes += "${Description}: ${stepElapsed}s"
}

# ── Main ──────────────────────────────────────────
Import-Config
Parse-CommonArgs $RemainingArgs

if ($SkipBenchmark) { $script:SkipBenchmark = $true }
if ($DryRun) { $script:DryRun = $true }

Write-Config

$totalStart = Get-Date
$script:StepTimes = @()

# ── Forward args to sub-scripts ─────────────────
$fwdArgs = @()
if (-not [string]::IsNullOrWhiteSpace($script:Subscription)) {
    $fwdArgs += '--subscription'
    $fwdArgs += $script:Subscription
}
if ($script:DryRun) {
    $fwdArgs += '--dry-run'
}

# ── Core setup (production-relevant) ────────────
Write-Log "══════ CORE SETUP ══════"
Invoke-Step -Script '01-create-storage.ps1' -Description 'Step 1: Create storage accounts' -ForwardArgs $fwdArgs
Invoke-Step -Script '02-enable-prereqs.ps1' -Description 'Step 2: Enable prerequisites' -ForwardArgs $fwdArgs

if (-not $script:SkipBenchmark) {
    # ── Benchmarking ──────────────────────────────
    Write-Log ""
    Write-Log "══════ BENCHMARKING (data ingestion before replication) ══════"
    Invoke-Step -Script 'bench-01-ingest-data.ps1' -Description 'Bench 1: Ingest test data' -ForwardArgs $fwdArgs
}

# Replication setup comes after initial data ingestion
Invoke-Step -Script '03-setup-replication.ps1' -Description 'Step 3: Setup object replication' -ForwardArgs $fwdArgs

if (-not $script:SkipBenchmark) {
    Invoke-Step -Script 'bench-02-continue-ingestion.ps1' -Description 'Bench 2: Continue ingestion' -ForwardArgs $fwdArgs
    Invoke-Step -Script 'bench-03-monitor-replication.ps1' -Description 'Bench 3: Monitor replication' -ForwardArgs $fwdArgs
}

# ── Summary ─────────────────────────────────────
$totalElapsed = [int](New-TimeSpan -Start $totalStart -End (Get-Date)).TotalSeconds

Write-Host ""
Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Log "ALL STEPS COMPLETE"
Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
foreach ($t in $script:StepTimes) {
    Write-Host "  • $t"
}
Write-Host "  ────────────────────────────"
Write-Ok "Total elapsed: ${totalElapsed}s"
Write-Host ""
Write-Log "To clean up: ./scripts/cleanup.ps1"
