# ─────────────────────────────────────────────────────────────────────────────
# 02-enable-prereqs.ps1 — Enable prerequisites for object replication
#
# Production-relevant: change feed, blob versioning, source containers.
# All operations are idempotent — safe to re-run.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [int]$ContainerCount,
    [string]$Subscription,
    [switch]$DryRun
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

Import-Config
Parse-CommonArgs $args
if ($PSBoundParameters.ContainsKey('ContainerCount')) { $script:ContainerCount = $ContainerCount }
if ($PSBoundParameters.ContainsKey('Subscription'))   { $script:Subscription  = $Subscription }
if ($DryRun) { $script:DryRun = $true }

Set-AzSubscription
Test-RequiredTool az

# ── Enable change feed on source account ────────
Write-Log "Enabling change feed on source account '$($script:SourceStorage)'..."
$cfEnabled = az storage account blob-service-properties show `
    --account-name $script:SourceStorage `
    --resource-group $script:ResourceGroup `
    --query "changeFeed.enabled" -o tsv 2>$null
if (-not $cfEnabled) { $cfEnabled = "false" }

if ($cfEnabled -eq "true") {
    Write-Ok "Change feed already enabled on '$($script:SourceStorage)'"
} else {
    Invoke-OrDry -Description "az storage account blob-service-properties update --enable-change-feed true" -Command {
        az storage account blob-service-properties update `
            --account-name $script:SourceStorage `
            --resource-group $script:ResourceGroup `
            --enable-change-feed true `
            --output none
    }
    Write-Ok "Change feed enabled on '$($script:SourceStorage)'"
}

# ── Enable blob versioning on both accounts ─────
foreach ($acct in @($script:SourceStorage, $script:DestStorage)) {
    Write-Log "Enabling blob versioning on '$acct'..."
    $verEnabled = az storage account blob-service-properties show `
        --account-name $acct `
        --resource-group $script:ResourceGroup `
        --query "isVersioningEnabled" -o tsv 2>$null
    if (-not $verEnabled) { $verEnabled = "false" }

    if ($verEnabled -eq "true") {
        Write-Ok "Blob versioning already enabled on '$acct'"
    } else {
        Invoke-OrDry -Description "az storage account blob-service-properties update --enable-versioning true on '$acct'" -Command {
            az storage account blob-service-properties update `
                --account-name $acct `
                --resource-group $script:ResourceGroup `
                --enable-versioning true `
                --output none
        }
        Write-Ok "Blob versioning enabled on '$acct'"
    }
}

# ── Create source containers ────────────────────
Write-Log "Creating $($script:ContainerCount) source container(s)..."
$srcKey = az storage account keys list `
    --account-name $script:SourceStorage `
    --resource-group $script:ResourceGroup `
    --query "[0].value" -o tsv

$width = ([string]$script:ContainerCount).Length
for ($i = 1; $i -le $script:ContainerCount; $i++) {
    $cname = "$($script:SourceContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
    $exists = az storage container exists `
        --name $cname `
        --account-name $script:SourceStorage `
        --account-key $srcKey `
        --query "exists" -o tsv 2>$null
    if (-not $exists) { $exists = "false" }

    if ($exists -eq "true") {
        Write-Ok "Container '$cname' already exists — reusing"
    } else {
        Invoke-OrDry -Description "az storage container create --name '$cname'" -Command {
            az storage container create `
                --name $cname `
                --account-name $script:SourceStorage `
                --account-key $srcKey `
                --output none
        }
        Write-Ok "Container '$cname' created"
    }
}

Write-Log "Prerequisites ready."
