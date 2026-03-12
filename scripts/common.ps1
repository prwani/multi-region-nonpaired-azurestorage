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
$script:AzDataMakerGitUrl = 'https://github.com/Azure/AzDataMaker.git'
$script:AzDataMakerDockerfile = 'src/AzDataMaker/AzDataMaker/Dockerfile'
$script:AzDataMakerImage = 'azdatamaker:latest'
$script:StorageBlobDataContributorRole = 'Storage Blob Data Contributor'

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
        $global:LASTEXITCODE = 0
        & $Command
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE."
        }
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
    $script:DataSizeGb            = [double](Resolve-Var 'DATA_SIZE_GB'   '1')
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
            '--data-size-gb'     { $script:DataSizeGb            = [double]$Arguments[++$i] }
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
    Write-Ok  "ACI instances:     $($script:AciCount) ($filesPerInstance files each, AzDataMaker only)"
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

function Get-AciName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Index)

    return '{0}-{1:D2}' -f $script:AciPrefix, $Index
}

function New-RandomBenchmarkFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$SizeMiB
    )

    [byte[]]$buffer = New-Object byte[] (1MB)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        for ($chunk = 0; $chunk -lt $SizeMiB; $chunk++) {
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
            $stream.Write($buffer, 0, $buffer.Length)
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-LocalBlobUploadBenchmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileNamePrefix,
        [Parameter(Mandatory)][string]$IntroMessage,
        [int]$ProgressEvery = 10
    )

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        Write-Log $IntroMessage
        $containers = (Get-ContainerNames -Prefix $script:SourceContainerPrefix).Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
        $containerIndex = 0

        for ($i = 1; $i -le $script:FileCount; $i++) {
            $sizeMiB = Get-Random -Minimum $script:MinFileSize -Maximum ($script:MaxFileSize + 1)
            $fileName = '{0}-{1:D4}.bin' -f $FileNamePrefix, $i
            $container = $containers[$containerIndex]
            $containerIndex = ($containerIndex + 1) % $containers.Count
            $filePath = Join-Path $tempDir $fileName

            if (-not $script:DryRun) {
                New-RandomBenchmarkFile -Path $filePath -SizeMiB $sizeMiB
            }

            Invoke-OrDry -Description "az storage blob upload --account-name '$($script:SourceStorage)' --container-name '$container' --name '$fileName'" -Command {
                az storage blob upload `
                    --account-name $script:SourceStorage `
                    --container-name $container `
                    --name $fileName `
                    --file $filePath `
                    --auth-mode login `
                    --overwrite `
                    --no-progress `
                    --output none
            }

            if (-not $script:DryRun -and (Test-Path $filePath)) {
                Remove-Item $filePath -Force
            }

            if ($i % $ProgressEvery -eq 0) {
                Write-Ok "$i/$($script:FileCount) files uploaded"
            }
        }

        Write-Ok "All $($script:FileCount) files uploaded"
    }
    finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-AzDataMakerInfrastructure {
    [CmdletBinding()]
    param()

    Write-Log "Setting up Azure Container Registry '$($script:AcrName)'..."

    $acrExists = $false
    if (-not $script:DryRun) {
        $acrId = az acr show --name $script:AcrName --resource-group $script:ResourceGroup --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($acrId)) {
            $acrExists = $true
        }
    }

    if ($acrExists) {
        Write-Ok "ACR '$($script:AcrName)' already exists — reusing"
    }
    else {
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

    Invoke-OrDry -Description "az acr update --name '$($script:AcrName)' --admin-enabled true" -Command {
        az acr update `
            --name $script:AcrName `
            --resource-group $script:ResourceGroup `
            --admin-enabled true `
            --output none
    }

    Write-Log 'Building AzDataMaker container image from Azure/AzDataMaker...'
    Invoke-OrDry -Description "az acr build --registry '$($script:AcrName)' --image $($script:AzDataMakerImage)" -Command {
        az acr build `
            --resource-group $script:ResourceGroup `
            --registry $script:AcrName `
            $script:AzDataMakerGitUrl `
            -f $script:AzDataMakerDockerfile `
            --image $script:AzDataMakerImage `
            --no-logs `
            --output none
    }
    Write-Ok 'AzDataMaker image ready'

    if ($script:DryRun) {
        return @{
            AcrServer         = "$($script:AcrName).azurecr.io"
            AcrUser           = '<dry-run>'
            AcrPassword       = '<dry-run>'
            SourceStorageId   = "/subscriptions/<subscription>/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($script:SourceStorage)"
            StorageAccountUri = "https://$($script:SourceStorage).blob.core.windows.net/"
        }
    }

    $acrServer = az acr show --name $script:AcrName --resource-group $script:ResourceGroup --query loginServer -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrServer)) {
        throw "Failed to resolve login server for ACR '$($script:AcrName)'."
    }

    $acrUser = az acr credential show --name $script:AcrName --resource-group $script:ResourceGroup --query username -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrUser)) {
        throw "Failed to resolve username for ACR '$($script:AcrName)'."
    }

    $acrPassword = az acr credential show --name $script:AcrName --resource-group $script:ResourceGroup --query "passwords[0].value" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrPassword)) {
        throw "Failed to resolve credentials for ACR '$($script:AcrName)'."
    }

    $sourceStorageId = az storage account show --name $script:SourceStorage --resource-group $script:ResourceGroup --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceStorageId)) {
        throw "Failed to resolve resource ID for storage account '$($script:SourceStorage)'."
    }

    $storageAccountUri = az storage account show --name $script:SourceStorage --resource-group $script:ResourceGroup --query primaryEndpoints.blob -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageAccountUri)) {
        throw "Failed to resolve blob endpoint for storage account '$($script:SourceStorage)'."
    }

    return @{
        AcrServer         = $acrServer
        AcrUser           = $acrUser
        AcrPassword       = $acrPassword
        SourceStorageId   = $sourceStorageId
        StorageAccountUri = $storageAccountUri
    }
}

function Test-AzDataMakerContainerCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AciName)

    try {
        $principalId = az container show `
            --name $AciName `
            --resource-group $script:ResourceGroup `
            --query identity.principalId -o tsv 2>$null
        $storageAccountUri = az container show `
            --name $AciName `
            --resource-group $script:ResourceGroup `
            --query "containers[0].environmentVariables[?name=='StorageAccountUri'].value | [0]" -o tsv 2>$null

        return (-not [string]::IsNullOrWhiteSpace($principalId) -and -not [string]::IsNullOrWhiteSpace($storageAccountUri))
    }
    catch {
        return $false
    }
}

function Wait-AciPrincipalId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AciName,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 5
    )

    if ($script:DryRun) {
        return '<dry-run-principal-id>'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $principalId = az container show `
            --name $AciName `
            --resource-group $script:ResourceGroup `
            --query identity.principalId -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            $principalId = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($principalId)) {
            return $principalId
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    throw "Managed identity principalId for ACI '$AciName' was not available in time."
}

function Wait-AciDeletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AciName,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 5
    )

    if ($script:DryRun) {
        return
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $existing = az container show `
                --name $AciName `
                --resource-group $script:ResourceGroup `
                --query id -o tsv 2>$null
        }
        catch {
            return
        }

        if ([string]::IsNullOrWhiteSpace($existing)) {
            return
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    throw "Timed out waiting for ACI '$AciName' to delete."
}

function Ensure-StorageBlobDataContributorRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$AciName
    )

    if ($script:DryRun) {
        Write-Dry "Would assign '$($script:StorageBlobDataContributorRole)' to '$AciName' ($PrincipalId) on '$Scope'"
        return
    }

    $existingAssignments = az role assignment list `
        --assignee-object-id $PrincipalId `
        --assignee-principal-type ServicePrincipal `
        --scope $Scope `
        --query "[?roleDefinitionName=='$($script:StorageBlobDataContributorRole)'] | length(@)" -o tsv 2>$null

    if ([string]::IsNullOrWhiteSpace($existingAssignments)) {
        $existingAssignments = '0'
    }

    if ([int]$existingAssignments -ge 1) {
        Write-Ok "ACI '$AciName' already has '$($script:StorageBlobDataContributorRole)'"
        return
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        az role assignment create `
            --assignee-object-id $PrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role $script:StorageBlobDataContributorRole `
            --scope $Scope `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Granted '$($script:StorageBlobDataContributorRole)' to ACI '$AciName'"
            return
        }

        if ($attempt -eq 12) {
            throw "Failed to assign '$($script:StorageBlobDataContributorRole)' to ACI '$AciName'."
        }

        Write-Warn "Waiting for managed identity '$AciName' to become assignable..."
        Start-Sleep -Seconds 10
    }
}

function Deploy-AzDataMakerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AciName,
        [Parameter(Mandatory)][hashtable]$Infrastructure,
        [Parameter(Mandatory)][string]$BlobContainers,
        [int]$ReportStatusIncrement = 100,
        [switch]$ReuseCompatible
    )

    if (-not $script:DryRun) {
        $existingAci = az container show `
            --name $AciName `
            --resource-group $script:ResourceGroup `
            --query id -o tsv 2>$null

        if (-not [string]::IsNullOrWhiteSpace($existingAci)) {
            if ($ReuseCompatible -and (Test-AzDataMakerContainerCompatibility -AciName $AciName)) {
                Write-Ok "ACI '$AciName' already exists — reusing"
                $principalId = az container show `
                    --name $AciName `
                    --resource-group $script:ResourceGroup `
                    --query identity.principalId -o tsv 2>$null
                if (-not [string]::IsNullOrWhiteSpace($principalId)) {
                    Ensure-StorageBlobDataContributorRole -PrincipalId $principalId -Scope $Infrastructure.SourceStorageId -AciName $AciName
                }
                return
            }

            if ($ReuseCompatible) {
                Write-Warn "ACI '$AciName' exists but does not use managed identity + StorageAccountUri — recreating"
            }
            else {
                Write-Warn "ACI '$AciName' already exists — recreating"
            }

            az container delete `
                --name $AciName `
                --resource-group $script:ResourceGroup `
                --yes `
                --output none
            Wait-AciDeletion -AciName $AciName
        }
    }

    Invoke-OrDry -Description "az container create --name '$AciName'" -Command {
        az container create `
            --name $AciName `
            --resource-group $script:ResourceGroup `
            --location $script:SourceRegion `
            --os-type Linux `
            --cpu 1 `
            --memory 1 `
            --registry-login-server $Infrastructure.AcrServer `
            --registry-username $Infrastructure.AcrUser `
            --registry-password $Infrastructure.AcrPassword `
            --image "$($Infrastructure.AcrServer)/$($script:AzDataMakerImage)" `
            --restart-policy Never `
            --assign-identity `
            --environment-variables `
                FileCount="$($script:FilesPerInstance)" `
                MaxFileSize="$($script:MaxFileSize)" `
                MinFileSize="$($script:MinFileSize)" `
                ReportStatusIncrement="$ReportStatusIncrement" `
                BlobContainers="$BlobContainers" `
                RandomFileContents='false' `
                StorageAccountUri="$($Infrastructure.StorageAccountUri)" `
            --output none
    }

    if (-not $script:DryRun) {
        $principalId = Wait-AciPrincipalId -AciName $AciName
        Ensure-StorageBlobDataContributorRole -PrincipalId $principalId -Scope $Infrastructure.SourceStorageId -AciName $AciName
    }

    Write-Ok "ACI '$AciName' deployed"
}

function Wait-AciInstancesCompletion {
    [CmdletBinding()]
    param([string[]]$AciNames)

    if ($script:DryRun -or -not $AciNames -or $AciNames.Count -eq 0) {
        return
    }

    Write-Log 'Waiting for ACI instances to complete...'
    $allDone = $false
    while (-not $allDone) {
        $allDone = $true
        foreach ($aciName in $AciNames) {
            $state = az container show `
                --name $aciName `
                --resource-group $script:ResourceGroup `
                --query instanceView.state -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($state)) {
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

function Get-MaxAciIndex {
    [CmdletBinding()]
    param()

    if ($script:DryRun) {
        return 0
    }

    try {
        $aciNames = az container list `
            --resource-group $script:ResourceGroup `
            --query "[?starts_with(name, '$($script:AciPrefix)-')].name" -o tsv 2>$null
    }
    catch {
        return 0
    }

    $maxIndex = 0
    foreach ($aciName in ($aciNames -split "`r?`n")) {
        if ($aciName -match "^$([regex]::Escape($script:AciPrefix))-(\d+)$") {
            $candidate = [int]$Matches[1]
            if ($candidate -gt $maxIndex) {
                $maxIndex = $candidate
            }
        }
    }

    return $maxIndex
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
    Write-Host "  │ ACI count:          $($script:AciCount) (AzDataMaker only)"
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
