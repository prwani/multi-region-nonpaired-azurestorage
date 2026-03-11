# ─────────────────────────────────────────────────────────────────────────────
# 01-create-storage.ps1 — Create resource group and source/destination storage accounts
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [string]$SourceRegion,
    [string]$DestRegion,
    [string]$ResourceGroup,
    [string]$Subscription,
    [switch]$DryRun
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

Import-Config
Parse-CommonArgs $args
if ($PSBoundParameters.ContainsKey('SourceRegion'))  { $script:SourceRegion  = $SourceRegion }
if ($PSBoundParameters.ContainsKey('DestRegion'))    { $script:DestRegion    = $DestRegion }
if ($PSBoundParameters.ContainsKey('ResourceGroup')) { $script:ResourceGroup = $ResourceGroup }
if ($PSBoundParameters.ContainsKey('Subscription'))  { $script:Subscription  = $Subscription }
if ($DryRun) { $script:DryRun = $true }

Set-AzSubscription
Write-Config
Test-RequiredTool az

# ── Resource Group ──────────────────────────────
Write-Log "Creating resource group '$($script:ResourceGroup)' in $($script:SourceRegion)..."
$rgExists = az group show --name $script:ResourceGroup 2>$null
if ($rgExists) {
    Write-Ok "Resource group '$($script:ResourceGroup)' already exists — reusing"
} else {
    Invoke-OrDry -Description "az group create --name '$($script:ResourceGroup)' --location '$($script:SourceRegion)'" -Command {
        az group create `
            --name $script:ResourceGroup `
            --location $script:SourceRegion `
            --output none
    }
    Write-Ok "Resource group '$($script:ResourceGroup)' created"
}

# ── Source Storage Account ──────────────────────
Write-Log "Creating source storage account '$($script:SourceStorage)' in $($script:SourceRegion)..."
$srcExists = az storage account show --name $script:SourceStorage --resource-group $script:ResourceGroup 2>$null
if ($srcExists) {
    Write-Ok "Source storage account '$($script:SourceStorage)' already exists — reusing"
} else {
    Invoke-OrDry -Description "az storage account create --name '$($script:SourceStorage)' ..." -Command {
        az storage account create `
            --name $script:SourceStorage `
            --resource-group $script:ResourceGroup `
            --location $script:SourceRegion `
            --kind StorageV2 `
            --sku Standard_LRS `
            --access-tier Hot `
            --https-only true `
            --output none
    }
    Write-Ok "Source storage account '$($script:SourceStorage)' created"
}

# ── Destination Storage Account ─────────────────
Write-Log "Creating destination storage account '$($script:DestStorage)' in $($script:DestRegion)..."
$dstExists = az storage account show --name $script:DestStorage --resource-group $script:ResourceGroup 2>$null
if ($dstExists) {
    Write-Ok "Destination storage account '$($script:DestStorage)' already exists — reusing"
} else {
    Invoke-OrDry -Description "az storage account create --name '$($script:DestStorage)' ..." -Command {
        az storage account create `
            --name $script:DestStorage `
            --resource-group $script:ResourceGroup `
            --location $script:DestRegion `
            --kind StorageV2 `
            --sku Standard_LRS `
            --access-tier Hot `
            --https-only true `
            --output none
    }
    Write-Ok "Destination storage account '$($script:DestStorage)' created"
}

Write-Log "Storage accounts ready."
