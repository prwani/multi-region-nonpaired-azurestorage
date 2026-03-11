# ─────────────────────────────────────────────────────────────────────────────
# bench-01-ingest-data.ps1 — Generate test data using AzDataMaker
#
# BENCHMARKING ONLY — ACR, ACI, and AzDataMaker are not part of a production
# object replication setup. This script creates test data to measure
# replication performance.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

function usage {
    Write-Host "Usage: bench-01-ingest-data.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Deploy AzDataMaker via ACR/ACI to generate test data in source containers."
    Write-Host "This is for benchmarking only — not part of production setup."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --data-size-gb <n>     Total data to generate in GB (default: 1)"
    Write-Host "  --aci-count <n>        Number of ACI instances (default: 1)"
    Write-Host "  --container-count <n>  Number of containers (default: 5)"
    Write-Host "  --subscription <id>    Azure subscription ID"
    Write-Host "  --dry-run              Preview without executing"
    Write-Host "  -h, --help             Show this help"
}

Import-Config
Parse-CommonArgs $args
Set-AzSubscription

Test-RequiredTool 'az'

$startTime = Get-Date

# ── Create ACR (BENCHMARKING ONLY) ───────────────
Write-Log "Setting up Azure Container Registry '$($script:AcrName)'..."
$acrExists = az acr show --name $script:AcrName --resource-group $script:ResourceGroup 2>$null
if ($acrExists) {
    Write-Ok "ACR '$($script:AcrName)' already exists — reusing"
} else {
    Invoke-OrDry -Description "az acr create --name '$($script:AcrName)'" -Command {
        az acr create `
            --name $script:AcrName `
            --resource-group $script:ResourceGroup `
            --admin-enabled true `
            --sku Standard `
            --location $script:SourceRegion `
            --output none
    }
    Write-Ok "ACR '$($script:AcrName)' created"
}

# ── Build AzDataMaker image (BENCHMARKING ONLY) ──
Write-Log "Building AzDataMaker container image..."
try {
    Invoke-OrDry -Description "az acr build --registry '$($script:AcrName)' --image azdatamaker:latest" -Command {
        az acr build `
            --resource-group $script:ResourceGroup `
            --registry $script:AcrName `
            https://github.com/Azure/azdatamaker.git `
            -f src/AzDataMaker/AzDataMaker/Dockerfile `
            --image azdatamaker:latest `
            --no-logs `
            --output none
    }
} catch {
    Write-Warn "ACR build returned non-zero — image may already exist"
}
Write-Ok "AzDataMaker image built"

# ── Compute data generation parameters ───────────
$params = Get-AzDataMakerParams

# ── Get credentials (BENCHMARKING ONLY) ──────────
$acrServer  = az acr show --name $script:AcrName --resource-group $script:ResourceGroup --query loginServer -o tsv
$acrUser    = az acr credential show --name $script:AcrName --resource-group $script:ResourceGroup --query username -o tsv
$acrPwd     = az acr credential show --name $script:AcrName --resource-group $script:ResourceGroup --query "passwords[0].value" -o tsv
$storageCs  = az storage account show-connection-string --name $script:SourceStorage --resource-group $script:ResourceGroup -o tsv

# ── Build container list ─────────────────────────
$containerNames = Get-ContainerNames -Prefix $script:SourceContainerPrefix

# ── Deploy ACI instances (BENCHMARKING ONLY) ─────
Write-Log "Deploying $($script:AciCount) ACI instance(s)..."
for ($x = 1; $x -le $script:AciCount; $x++) {
    $aciName = '{0}-{1:D2}' -f $script:AciPrefix, $x

    # Check if instance already exists (idempotent)
    $aciExists = az container show --name $aciName --resource-group $script:ResourceGroup 2>$null
    if ($aciExists) {
        Write-Ok "ACI '$aciName' already exists — skipping"
        continue
    }

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
                ReportStatusIncrement='100' `
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
            $aciName = '{0}-{1:D2}' -f $script:AciPrefix, $x
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

Write-Log "Data ingestion complete."
Write-Ok  "Elapsed time: ${elapsed}s"
Write-Ok  "Target data: ~$($script:DataSizeGb) GB across $($script:ContainerCount) container(s)"
