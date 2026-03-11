# ─────────────────────────────────────────────────────────────────────────────
# common.ps1 — Shared functions for multi-region-nonpaired-azurestorage
#
# Dot-source this file at the top of every script:
#   . "$PSScriptRoot/common.ps1"
# ─────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'

# ── Globals ───────────────────────────────────────
$script:DryRun        = $false
$script:Yes           = $false
$script:SkipBenchmark = $false
$script:RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# ── Logging ───────────────────────────────────────

function Write-Log {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $($Message -join ' ')" -ForegroundColor Cyan
}

function Write-Ok {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host "  ✔ $($Message -join ' ')" -ForegroundColor Green
}

function Write-Warn {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host "  ⚠ $($Message -join ' ')" -ForegroundColor Yellow
}

function Write-Err {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host "  ✖ $($Message -join ' ')" -ForegroundColor Red
}

function Write-Dry {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host "  [DRY-RUN] $($Message -join ' ')" -ForegroundColor Yellow
}

# ── Helpers ───────────────────────────────────────

function Invoke-OrDry {
    <#
    .SYNOPSIS
        Runs a scriptblock, or prints a dry-run preview when $script:DryRun is $true.
    .PARAMETER Command
        The scriptblock to execute.
    .PARAMETER Description
        Human-readable description shown during dry-run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Command,
        [string]$Description
    )
    if ($script:DryRun) {
        $text = if ($Description) { $Description } else { $Command.ToString().Trim() }
        Write-Dry "Would run: $text"
    } else {
        & $Command
    }
}

function Test-RequiredTool {
    <#
    .SYNOPSIS
        Checks that a CLI tool is available on PATH.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        Write-Err "'$Tool' is required but not installed."
        exit 1
    }
}

# ── Configuration loading ────────────────────────

function Import-Config {
    <#
    .SYNOPSIS
        Reads config.env from the repo root, parses key=value lines (skipping
        comments), and sets $script: variables only when not already set via
        environment. Applies built-in defaults and auto-generates random names
        for storage accounts / ACR when left blank.
    #>
    [CmdletBinding()]
    param()

    $configFile = Join-Path $script:RepoRoot 'config.env'

    # Helper: return env var value or $null
    function Get-EnvOrNull([string]$Name) {
        $v = [System.Environment]::GetEnvironmentVariable($Name)
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return $v
    }

    # Collect values from config.env (lower priority than env vars)
    $fileVars = @{}
    if (Test-Path $configFile) {
        foreach ($line in Get-Content $configFile) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            $eqIdx = $trimmed.IndexOf('=')
            if ($eqIdx -lt 1) { continue }
            $key   = $trimmed.Substring(0, $eqIdx).Trim()
            $raw   = $trimmed.Substring($eqIdx + 1).Trim()
            # Strip surrounding quotes, then remove trailing inline comments
            if ($raw.Length -ge 2 -and (($raw[0] -eq '"' -and $raw.Contains('"')) -or ($raw[0] -eq "'" -and $raw.Contains("'")))) {
                $quote  = $raw[0]
                $endIdx = $raw.IndexOf($quote, 1)
                if ($endIdx -gt 0) {
                    $raw = $raw.Substring(1, $endIdx - 1)
                }
            }
            $value = $raw.Trim()
            $fileVars[$key] = $value
        }
    }

    # Resolve helper: env var → config.env → default
    function Resolve-Var([string]$EnvName, [string]$Default = '') {
        $env = Get-EnvOrNull $EnvName
        if ($null -ne $env) { return $env }
        if ($fileVars.ContainsKey($EnvName) -and -not [string]::IsNullOrWhiteSpace($fileVars[$EnvName])) {
            return $fileVars[$EnvName]
        }
        return $Default
    }

    # Apply built-in defaults
    $script:SourceRegion          = Resolve-Var 'SOURCE_REGION'           'swedencentral'
    $script:DestRegion            = Resolve-Var 'DEST_REGION'             'norwayeast'
    $script:ResourceGroup         = Resolve-Var 'RESOURCE_GROUP'          'rg-objrepl-demo'
    $script:Subscription          = Resolve-Var 'SUBSCRIPTION'            ''
    $script:ContainerCount        = [int](Resolve-Var 'CONTAINER_COUNT'   '5')
    $script:SourceContainerPrefix = Resolve-Var 'SOURCE_CONTAINER_PREFIX' 'source'
    $script:DestContainerPrefix   = Resolve-Var 'DEST_CONTAINER_PREFIX'   'dest'
    $script:ReplicationMode       = Resolve-Var 'REPLICATION_MODE'        'default'
    $script:DataSizeGb            = [int](Resolve-Var 'DATA_SIZE_GB'      '1')
    $script:AciCount              = [int](Resolve-Var 'ACI_COUNT'         '1')
    $script:MaxFileSize           = [int](Resolve-Var 'MAX_FILE_SIZE'     '12')
    $script:MinFileSize           = [int](Resolve-Var 'MIN_FILE_SIZE'     '8')
    $script:FileCount             = Resolve-Var 'FILE_COUNT'              ''
    $script:AciPrefix             = Resolve-Var 'ACI_PREFIX'              'azdatamaker'

    # Auto-generate storage / ACR names with stable suffix derived from resource group
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:ResourceGroup)
    $hash = $md5.ComputeHash($bytes)
    $suffix = -join ($hash[0..2] | ForEach-Object { $_.ToString('x2') })

    $srcStorage = Resolve-Var 'SOURCE_STORAGE' ''
    $script:SourceStorage = if ([string]::IsNullOrWhiteSpace($srcStorage)) { "objreplsrc$suffix" } else { $srcStorage }

    $dstStorage = Resolve-Var 'DEST_STORAGE' ''
    $script:DestStorage = if ([string]::IsNullOrWhiteSpace($dstStorage)) { "objrepldst$suffix" } else { $dstStorage }

    $acrName = Resolve-Var 'ACR_NAME' ''
    $script:AcrName = if ([string]::IsNullOrWhiteSpace($acrName)) { "objreplacr$suffix" } else { $acrName }
}

# ── CLI argument parsing ─────────────────────────

function Parse-CommonArgs {
    <#
    .SYNOPSIS
        Parses common CLI arguments and sets $script: variables.
        Returns an array of any unrecognised arguments.
    .PARAMETER Arguments
        The raw argument list (typically $args from the caller).
    #>
    [CmdletBinding()]
    param([string[]]$Arguments)

    $remaining = @()
    $i = 0
    while ($i -lt $Arguments.Count) {
        switch ($Arguments[$i]) {
            '--source-region'    { $script:SourceRegion          = $Arguments[++$i] }
            '--dest-region'      { $script:DestRegion            = $Arguments[++$i] }
            '--resource-group'   { $script:ResourceGroup         = $Arguments[++$i] }
            '--subscription'     { $script:Subscription          = $Arguments[++$i] }
            '--source-storage'   { $script:SourceStorage         = $Arguments[++$i] }
            '--dest-storage'     { $script:DestStorage           = $Arguments[++$i] }
            '--container-count'  { $script:ContainerCount        = [int]$Arguments[++$i] }
            '--replication-mode' { $script:ReplicationMode       = $Arguments[++$i] }
            '--data-size-gb'     { $script:DataSizeGb            = [int]$Arguments[++$i] }
            '--aci-count'        { $script:AciCount              = [int]$Arguments[++$i] }
            '--max-file-size'    { $script:MaxFileSize           = [int]$Arguments[++$i] }
            '--min-file-size'    { $script:MinFileSize           = [int]$Arguments[++$i] }
            '--file-count'       { $script:FileCount             = [int]$Arguments[++$i] }
            '--acr-name'         { $script:AcrName               = $Arguments[++$i] }
            '--dry-run'          { $script:DryRun                = $true }
            { $_ -in '--yes', '-y' } { $script:Yes              = $true }
            '--skip-benchmark'   { $script:SkipBenchmark         = $true }
            '-h'                 { if (Get-Command usage -ErrorAction SilentlyContinue) { usage }; exit 0 }
            '--help'             { if (Get-Command usage -ErrorAction SilentlyContinue) { usage }; exit 0 }
            default              { $remaining += $Arguments[$i] }
        }
        $i++
    }
    return $remaining
}

# ── AzDataMaker parameter computation ────────────

function Get-AzDataMakerParams {
    <#
    .SYNOPSIS
        Computes FILE_COUNT from DATA_SIZE_GB, MAX/MIN_FILE_SIZE and divides
        work across ACI_COUNT instances. Returns a hashtable with computed values.
    #>
    [CmdletBinding()]
    param()

    if ($script:FileCount -and $script:FileCount -ne '' -and $script:FileCount -ne 0) {
        Write-Log "Using explicit FILE_COUNT=$($script:FileCount) (auto-calculation skipped)"
    } else {
        $avgFileSize = ($script:MaxFileSize + $script:MinFileSize) / 2.0
        $script:FileCount = [int][Math]::Ceiling(($script:DataSizeGb * 1024) / $avgFileSize)
        if ($script:FileCount -lt 1) { $script:FileCount = 1 }
    }

    $filesPerInstance = [int][Math]::Ceiling($script:FileCount / $script:AciCount)
    $estSize = [Math]::Round($script:FileCount * (($script:MaxFileSize + $script:MinFileSize) / 2.0) / 1024, 2)

    Write-Log 'Data generation plan:'
    Write-Ok  "Target size:       ~${estSize} GB"
    Write-Ok  "Files:             $($script:FileCount) ($($script:MinFileSize)–$($script:MaxFileSize) MiB each)"
    Write-Ok  "ACI instances:     $($script:AciCount) ($filesPerInstance files each)"
    Write-Ok  "Containers:        $($script:ContainerCount) (round-robin)"

    $script:FilesPerInstance = $filesPerInstance

    return @{
        FileCount        = $script:FileCount
        FilesPerInstance  = $filesPerInstance
        EstimatedSizeGb  = $estSize
    }
}

# ── Container name generation ────────────────────

function Get-ContainerNames {
    <#
    .SYNOPSIS
        Generates container names like "source-01", "source-02", etc.
    .PARAMETER Prefix
        The name prefix (e.g. "source" or "dest").
    .PARAMETER Count
        Number of containers. Defaults to $script:ContainerCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [int]$Count = $script:ContainerCount
    )

    $width = ([string]$Count).Length
    $names = @()
    for ($i = 1; $i -le $Count; $i++) {
        $names += "$Prefix-$($i.ToString().PadLeft($width, '0'))"
    }
    return ($names -join ',')
}

# ── Print resolved configuration ─────────────────

function Write-Config {
    <#
    .SYNOPSIS
        Prints the resolved configuration summary table.
    #>
    [CmdletBinding()]
    param()

    $sub = if ([string]::IsNullOrWhiteSpace($script:Subscription)) { '<default>' } else { $script:Subscription }

    Write-Log 'Resolved configuration:'
    Write-Host "  ┌─────────────────────────────────────────────────"
    Write-Host "  │ Source region:      $($script:SourceRegion)"
    Write-Host "  │ Dest region:        $($script:DestRegion)"
    Write-Host "  │ Resource group:     $($script:ResourceGroup)"
    Write-Host "  │ Subscription:       $sub"
    Write-Host "  │ Source storage:     $($script:SourceStorage)"
    Write-Host "  │ Dest storage:       $($script:DestStorage)"
    Write-Host "  │ Containers:         $($script:ContainerCount) ($($script:SourceContainerPrefix)-NN → $($script:DestContainerPrefix)-NN)"
    Write-Host "  │ Replication mode:   $($script:ReplicationMode)"
    Write-Host "  │ Data size:          $($script:DataSizeGb) GB"
    Write-Host "  │ ACI count:          $($script:AciCount)"
    Write-Host "  │ ACR name:           $($script:AcrName)"
    Write-Host "  └─────────────────────────────────────────────────"
}

# ── Subscription helper ──────────────────────────

function Set-AzSubscription {
    <#
    .SYNOPSIS
        Sets the active Azure subscription if one is configured.
    #>
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($script:Subscription)) {
        Write-Log "Setting subscription to $($script:Subscription)"
        Invoke-OrDry -Description "az account set --subscription '$($script:Subscription)'" -Command {
            az account set --subscription $script:Subscription
        }
    }
}
