# ─────────────────────────────────────────────────────────────────────────────
# bench-02-continue-ingestion.ps1 — Continue data generation after replication
#
# BENCHMARKING ONLY — Generates additional data after replication is active
# to measure ongoing replication latency (vs historical catchup).
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

function usage {
    Write-Host "Usage: bench-02-continue-ingestion.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Continue AzDataMaker after replication is active to measure ongoing latency."
    Write-Host "This is for benchmarking only — not part of production setup."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --data-size-gb <n>     Data to generate in this batch (default: 0.5)"
    Write-Host "  --aci-count <n>        Number of ACI instances (default: 1)"
    Write-Host "  --subscription <id>    Azure subscription ID"
    Write-Host "  --dry-run              Preview without executing"
    Write-Host "  -h, --help             Show this help"
}

Import-Config
Parse-CommonArgs $args
Set-AzSubscription

Test-RequiredTool 'az'

# Use a smaller default for continuation (BENCHMARKING ONLY)
$continueSizeGb = if ($env:CONTINUE_SIZE_GB) { [double]$env:CONTINUE_SIZE_GB } else { 0.5 }
$script:DataSizeGb = $continueSizeGb

$startTime = Get-Date

$params = Get-AzDataMakerParams

# ── Get credentials (BENCHMARKING ONLY) ──────────
$acrServer  = az acr show --name $script:AcrName --resource-group $script:ResourceGroup --query loginServer -o tsv
$acrUser    = az acr credential show --name $script:AcrName --resource-group $script:ResourceGroup --query username -o tsv
$acrPwd     = az acr credential show --name $script:AcrName --resource-group $script:ResourceGroup --query "passwords[0].value" -o tsv
$storageCs  = az storage account show-connection-string --name $script:SourceStorage --resource-group $script:ResourceGroup -o tsv

$containerNames = Get-ContainerNames -Prefix $script:SourceContainerPrefix

# ── Find next ACI index (BENCHMARKING ONLY) ──────
try {
    $maxIdx = [int](az container list `
        --resource-group $script:ResourceGroup `
        --query "length([?starts_with(name, '$($script:AciPrefix)-')])" -o tsv 2>$null)
} catch {
    $maxIdx = 0
}

# ── Deploy additional ACI instances (BENCHMARKING ONLY) ──
Write-Log "Deploying $($script:AciCount) additional ACI instance(s) for ongoing replication test..."
for ($x = 1; $x -le $script:AciCount; $x++) {
    $idx = $maxIdx + $x
    $aciName = '{0}-{1:D2}' -f $script:AciPrefix, $idx

    Invoke-OrDry -Description "az container create --name '$aciName'" -Command {
        az container create `
            --name $aciName `
            --resource-group $script:ResourceGroup `
            --location $script:SourceRegion `
            --cpu 1 `
            --memory 1 `
            --registry-login-server $acrServer `
            --registry-username $acrUser `
            --registry-password $acrPwd `
            --image "$acrServer/azdatamaker:latest" `
            --restart-policy Never `
            --no-wait `
            --environment-variables `
                FileCount="$($script:FilesPerInstance)" `
                MaxFileSize="$($script:MaxFileSize)" `
                MinFileSize="$($script:MinFileSize)" `
                ReportStatusIncrement='50' `
                BlobContainers="$containerNames" `
                RandomFileContents='false' `
            --secure-environment-variables `
                ConnectionStrings__MyStorageConnection="$storageCs" `
            --output none
    }
    Write-Ok "ACI '$aciName' deployed"
}

# ── Wait for completion ──────────────────────────
if (-not $script:DryRun) {
    Write-Log "Waiting for ACI instances to complete..."
    $allDone = $false
    while (-not $allDone) {
        $allDone = $true
        for ($x = 1; $x -le $script:AciCount; $x++) {
            $idx = $maxIdx + $x
            $aciName = '{0}-{1:D2}' -f $script:AciPrefix, $idx
            try {
                $state = az container show `
                    --name $aciName `
                    --resource-group $script:ResourceGroup `
                    --query "instanceView.state" -o tsv 2>$null
            } catch {
                $state = 'Unknown'
            }
            if ($state -notin 'Succeeded', 'Failed', 'Terminated') {
                $allDone = $false
            }
        }
        if (-not $allDone) {
            Write-Host -NoNewline '.'
            Start-Sleep -Seconds 15
        }
    }
    Write-Host ''
}

$endTime = Get-Date
$elapsed = [int]($endTime - $startTime).TotalSeconds

Write-Log "Continued ingestion complete."
Write-Ok  "Elapsed: ${elapsed}s"
Write-Ok  "Additional data: ~$($script:DataSizeGb) GB"
Write-Log "Run bench-03-monitor-replication.ps1 to measure replication latency."
