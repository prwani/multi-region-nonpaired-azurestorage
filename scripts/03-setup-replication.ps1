# ─────────────────────────────────────────────────────────────────────────────
# 03-setup-replication.ps1 — Configure object replication between storage accounts
#
# Creates destination containers and sets up replication policy with rules
# for each container pair. Supports default and priority replication modes.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [string]$ReplicationMode,
    [int]$ContainerCount,
    [string]$Subscription,
    [switch]$DryRun
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

Import-Config
Parse-CommonArgs $args
if ($PSBoundParameters.ContainsKey('ReplicationMode')) { $script:ReplicationMode = $ReplicationMode }
if ($PSBoundParameters.ContainsKey('ContainerCount'))  { $script:ContainerCount  = $ContainerCount }
if ($PSBoundParameters.ContainsKey('Subscription'))    { $script:Subscription    = $Subscription }
if ($DryRun) { $script:DryRun = $true }

Set-AzSubscription
Test-RequiredTool az

# ── Create destination containers ───────────────
Write-Log "Creating $($script:ContainerCount) destination container(s)..."
$width = ([string]$script:ContainerCount).Length
for ($i = 1; $i -le $script:ContainerCount; $i++) {
    $cname = "$($script:DestContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
    $exists = az storage container exists `
        --name $cname `
        --account-name $script:DestStorage `
        --auth-mode login `
        --query "exists" -o tsv 2>$null
    if (-not $exists) { $exists = "false" }

    if ($exists -eq "true") {
        Write-Ok "Container '$cname' already exists — reusing"
    } else {
        Invoke-OrDry -Description "az storage container create --name '$cname'" -Command {
            az storage container create `
                --name $cname `
                --account-name $script:DestStorage `
                --auth-mode login `
                --output none
        }
        Write-Ok "Container '$cname' created"
    }
}

# ── Get account resource IDs ────────────────────
$srcId = az storage account show `
    --name $script:SourceStorage `
    --resource-group $script:ResourceGroup `
    --query "id" -o tsv

$dstId = az storage account show `
    --name $script:DestStorage `
    --resource-group $script:ResourceGroup `
    --query "id" -o tsv

# ── Create policy on destination account ────────
Write-Log "Creating replication policy on destination account '$($script:DestStorage)'..."

if ($script:ReplicationMode -eq "priority") {
    Write-Log "Enabling priority replication (99% within 15 min SLA for same-continent)"
}

Invoke-OrDry -Description "az storage account or-policy create on '$($script:DestStorage)'" -Command {
    az storage account or-policy create `
        --account-name $script:DestStorage `
        --resource-group $script:ResourceGroup `
        --source-account $srcId `
        --destination-account $dstId `
        --output json
}

# Get the policy ID from destination
$policyId = az storage account or-policy list `
    --account-name $script:DestStorage `
    --resource-group $script:ResourceGroup `
    --query "[0].policyId" -o tsv 2>$null

if ([string]::IsNullOrWhiteSpace($policyId)) {
    Write-Err "Failed to create or retrieve replication policy on destination account"
    exit 1
}
Write-Ok "Policy created on destination with ID: $policyId"

# ── Add rules to the policy ────────────────────
Write-Log "Adding $($script:ContainerCount) replication rule(s) to policy..."
for ($i = 1; $i -le $script:ContainerCount; $i++) {
    $srcContainer = "$($script:SourceContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
    $dstContainer = "$($script:DestContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
    Invoke-OrDry -Description "az storage account or-policy rule add: $srcContainer -> $dstContainer" -Command {
        az storage account or-policy rule add `
            --account-name $script:DestStorage `
            --resource-group $script:ResourceGroup `
            --policy-id $policyId `
            --source-container $srcContainer `
            --destination-container $dstContainer `
            --output none
    }
    Write-Ok "Rule: $srcContainer -> $dstContainer"
}

# ── Create matching policy on source account ────
Write-Log "Creating matching policy on source account '$($script:SourceStorage)'..."
$destPolicy = az storage account or-policy show `
    --account-name $script:DestStorage `
    --resource-group $script:ResourceGroup `
    --policy-id $policyId `
    --output json 2>$null

Invoke-OrDry -Description "az storage account or-policy create on '$($script:SourceStorage)'" -Command {
    az storage account or-policy create `
        --account-name $script:SourceStorage `
        --resource-group $script:ResourceGroup `
        --policy-id $policyId `
        --source-account $srcId `
        --destination-account $dstId `
        --output none
}
Write-Ok "Matching policy created on source account"

# ── Enable priority replication if requested ────
if ($script:ReplicationMode -eq "priority") {
    Write-Log "Enabling priority replication on policy $policyId..."
    Invoke-OrDry -Description "az storage account or-policy update (priority)" -Command {
        az storage account or-policy update `
            --account-name $script:DestStorage `
            --resource-group $script:ResourceGroup `
            --policy-id $policyId `
            --output none
    }
    Write-Ok "Priority replication enabled"
    Write-Warn "Note: priority replication has a per-GB ingress cost and billing continues 30 days after disabling"
}

Write-Log "Object replication configured successfully."
Write-Ok "Mode: $($script:ReplicationMode)"
Write-Ok "Policy ID: $policyId"
Write-Ok "Container pairs: $($script:ContainerCount)"
