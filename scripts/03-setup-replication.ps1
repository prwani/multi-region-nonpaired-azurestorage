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
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArgs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/common.ps1"

Import-Config
Parse-CommonArgs $RemainingArgs
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
Write-Log 'Copy scope: all objects (existing + new)'

if ($script:ReplicationMode -eq 'priority') {
    Write-Log 'Priority replication mode selected (99% within 15 min SLA for same-continent)'
}

if ($script:ContainerCount -gt 10) {
    # ── JSON policy approach (required for >10 container pairs) ──
    Write-Log 'Using JSON policy definition (required for >10 container pairs)'

    $rules = @()
    for ($i = 1; $i -le $script:ContainerCount; $i++) {
        $srcContainer = "$($script:SourceContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
        $dstContainer = "$($script:DestContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
        $rules += @{
            sourceContainer      = $srcContainer
            destinationContainer = $dstContainer
            filters              = @{ minCreationTime = '1601-01-01T00:00:00Z' }
        }
    }

    $policyObj = @{
        properties = @{
            sourceAccount      = $srcId
            destinationAccount = $dstId
            rules              = $rules
        }
    }
    if ($script:ReplicationMode -eq 'priority') {
        $policyObj.properties.priorityReplication = $true
    }

    $policyFile = [System.IO.Path]::GetTempFileName()
    try {
        $policyObj | ConvertTo-Json -Depth 10 | Set-Content -Path $policyFile -Encoding utf8

        Invoke-OrDry -Description "az storage account or-policy create on '$($script:DestStorage)' (JSON)" -Command {
            az storage account or-policy create `
                --account-name $script:DestStorage `
                --resource-group $script:ResourceGroup `
                --policy "@$policyFile" `
                --output none
        }
    }
    finally {
        Remove-Item $policyFile -Force -ErrorAction SilentlyContinue
    }

    $policyId = az storage account or-policy list `
        --account-name $script:DestStorage `
        --resource-group $script:ResourceGroup `
        --query "[0].policyId" -o tsv 2>$null

    if ([string]::IsNullOrWhiteSpace($policyId)) {
        Write-Err 'Failed to create or retrieve replication policy on destination account'
        exit 1
    }
    Write-Ok "Policy created on destination with ID: $policyId"
    Write-Ok "Rules: $($script:ContainerCount) container pairs configured via JSON policy"

} else {
    # ── Inline approach (<=10 container pairs) ─────
    $firstSrcContainer = '{0}-{1}' -f $script:SourceContainerPrefix, (1).ToString().PadLeft($width, '0')
    $firstDstContainer = '{0}-{1}' -f $script:DestContainerPrefix, (1).ToString().PadLeft($width, '0')
    $createArgs = @(
        'storage', 'account', 'or-policy', 'create',
        '--account-name', $script:DestStorage,
        '--resource-group', $script:ResourceGroup,
        '--source-account', $srcId,
        '--destination-account', $dstId,
        '--destination-container', $firstDstContainer,
        '--source-container', $firstSrcContainer,
        '--min-creation-time', '1601-01-01T00:00:00Z'
    )
    if ($script:ReplicationMode -eq 'priority') {
        $createArgs += @('--priority-replication', 'true')
    }
    $createArgs += @('--output', 'none')

    Invoke-OrDry -Description "az storage account or-policy create on '$($script:DestStorage)'" -Command {
        & az @createArgs
    }

    $policyId = az storage account or-policy list `
        --account-name $script:DestStorage `
        --resource-group $script:ResourceGroup `
        --query "[0].policyId" -o tsv 2>$null

    if ([string]::IsNullOrWhiteSpace($policyId)) {
        Write-Err 'Failed to create or retrieve replication policy on destination account'
        exit 1
    }
    Write-Ok "Policy created on destination with ID: $policyId"
    Write-Ok "Rule: $firstSrcContainer -> $firstDstContainer"

    # ── Add rules to the policy ────────────────────
    if ($script:ContainerCount -gt 1) {
        Write-Log "Adding $($script:ContainerCount - 1) remaining replication rule(s)..."
        for ($i = 2; $i -le $script:ContainerCount; $i++) {
            $srcContainer = "$($script:SourceContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
            $dstContainer = "$($script:DestContainerPrefix)-$($i.ToString().PadLeft($width, '0'))"
            Invoke-OrDry -Description "az storage account or-policy rule add: $srcContainer -> $dstContainer" -Command {
                az storage account or-policy rule add `
                    --account-name $script:DestStorage `
                    --resource-group $script:ResourceGroup `
                    --policy-id $policyId `
                    --source-container $srcContainer `
                    --destination-container $dstContainer `
                    --min-creation-time '1601-01-01T00:00:00Z' `
                    --output none
            }
            Write-Ok "Rule: $srcContainer -> $dstContainer"
        }
    }
}

# ── Create matching policy on source account ────
Write-Log "Creating matching policy on source account '$($script:SourceStorage)'..."
$destPolicy = az storage account or-policy show `
    --account-name $script:DestStorage `
    --resource-group $script:ResourceGroup `
    --policy-id $policyId `
    --output json 2>$null

$policyFile = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -Path $policyFile -Value $destPolicy -Encoding utf8

    Invoke-OrDry -Description "az storage account or-policy create on '$($script:SourceStorage)'" -Command {
        az storage account or-policy create `
            --account-name $script:SourceStorage `
            --resource-group $script:ResourceGroup `
            --policy "@$policyFile" `
            --output none
    }
    Write-Ok 'Matching policy created on source account'
}
finally {
    Remove-Item $policyFile -Force -ErrorAction SilentlyContinue
}

# ── Priority replication note ───────────────────
if ($script:ReplicationMode -eq 'priority') {
    Write-Ok 'Priority replication enabled'
    Write-Warn 'Note: priority replication has a per-GB ingress cost and billing continues 30 days after disabling'
}

Write-Log "Object replication configured successfully."
Write-Ok "Mode: $($script:ReplicationMode)"
Write-Ok "Policy ID: $policyId"
Write-Ok "Container pairs: $($script:ContainerCount)"
