# ─────────────────────────────────────────────────────────────────────────────
# cleanup.ps1 — Teardown all resources created by this demo
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArgs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

function usage {
    Write-Host "Usage: cleanup.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Delete all resources created by the object replication demo."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Yes                   Skip confirmation prompt"
    Write-Host "  --subscription <id>    Azure subscription ID"
    Write-Host "  -DryRun                Preview without executing"
    Write-Host "  -h, --help             Show this help"
}

# ── Main ──────────────────────────────────────────
Import-Config
Parse-CommonArgs $RemainingArgs

if ($Yes) { $script:Yes = $true }
if ($DryRun) { $script:DryRun = $true }

Set-AzSubscription
Write-Config

Test-RequiredTool 'az'

# ── Confirmation ────────────────────────────────
if (-not $script:Yes -and -not $script:DryRun) {
    Write-Host ""
    Write-Warn "This will DELETE the following resources:"
    Write-Host "  • Resource group:    $($script:ResourceGroup)"
    Write-Host "  • Storage accounts:  $($script:SourceStorage), $($script:DestStorage)"
    Write-Host "  • ACR:               $($script:AcrName)"
    Write-Host "  • ACI instances:     $($script:AciPrefix)-*"
    Write-Host ""
    $confirm = Read-Host "Are you sure? (y/N)"
    if ($confirm -notmatch '^[yY]$') {
        Write-Log "Aborted."
        exit 0
    }
}

# ── Delete replication policies ─────────────────
Write-Log "Removing replication policies..."
$policies = @()
$policiesRaw = az storage account or-policy list `
    --account-name $script:DestStorage `
    --resource-group $script:ResourceGroup `
    --query "[].policyId" -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $policiesRaw) {
    $policies = ($policiesRaw -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

foreach ($policyId in $policies) {
    try {
        Invoke-OrDry `
            -Description "az storage account or-policy delete --account-name '$($script:DestStorage)' --resource-group '$($script:ResourceGroup)' --policy-id '$policyId'" `
            -Command {
                az storage account or-policy delete `
                    --account-name $script:DestStorage `
                    --resource-group $script:ResourceGroup `
                    --policy-id $policyId `
                    --output none
            }
    } catch { }
    try {
        Invoke-OrDry `
            -Description "az storage account or-policy delete --account-name '$($script:SourceStorage)' --resource-group '$($script:ResourceGroup)' --policy-id '$policyId'" `
            -Command {
                az storage account or-policy delete `
                    --account-name $script:SourceStorage `
                    --resource-group $script:ResourceGroup `
                    --policy-id $policyId `
                    --output none
            }
    } catch { }
    Write-Ok "Deleted policy $policyId"
}

# ── Delete ACI instances ────────────────────────
Write-Log "Deleting ACI instances..."
$instances = @()
$instancesRaw = az container list `
    --resource-group $script:ResourceGroup `
    --query "[?starts_with(name, '$($script:AciPrefix)-')].name" -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $instancesRaw) {
    $instances = ($instancesRaw -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

foreach ($inst in $instances) {
    try {
        Invoke-OrDry `
            -Description "az container delete --name '$inst' --resource-group '$($script:ResourceGroup)' --yes" `
            -Command {
                az container delete `
                    --name $inst `
                    --resource-group $script:ResourceGroup `
                    --yes `
                    --output none
            }
    } catch { }
    Write-Ok "Deleted ACI: $inst"
}
if ($instances.Count -eq 0) {
    Write-Ok "No ACI instances found"
}

# ── Delete ACR ──────────────────────────────────
Write-Log "Deleting container registry '$($script:AcrName)'..."
az acr show --name $script:AcrName --resource-group $script:ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Invoke-OrDry `
        -Description "az acr delete --name '$($script:AcrName)' --resource-group '$($script:ResourceGroup)' --yes" `
        -Command {
            az acr delete `
                --name $script:AcrName `
                --resource-group $script:ResourceGroup `
                --yes `
                --output none
        }
    Write-Ok "ACR '$($script:AcrName)' deleted"
} else {
    Write-Ok "ACR '$($script:AcrName)' not found — skipping"
}

# ── Delete resource group (includes storage accounts) ──
Write-Log "Deleting resource group '$($script:ResourceGroup)'..."
az group show --name $script:ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Invoke-OrDry `
        -Description "az group delete --name '$($script:ResourceGroup)' --yes --no-wait" `
        -Command {
            az group delete `
                --name $script:ResourceGroup `
                --yes `
                --no-wait `
                --output none
        }
    Write-Ok "Resource group '$($script:ResourceGroup)' deletion initiated (--no-wait)"
} else {
    Write-Ok "Resource group '$($script:ResourceGroup)' not found — skipping"
}

Write-Log "Cleanup complete."
