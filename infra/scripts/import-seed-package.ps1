[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [string]$ContainerName = 'critical-notices',

    [int]$Days = 10,

    [string[]]$Sources = @('enbridge', 'tceconnects'),

    [string]$SeedPath = (Join-Path $PSScriptRoot '..\seed-package'),

    [switch]$Overwrite,

    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-Az {
    param([string[]]$AzArgs)
    $output = az @AzArgs --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($AzArgs -join ' ')"
    }
    return $output
}

function Invoke-AzCopy {
    param(
        [string]$Source,
        [string]$Target,
        [string[]]$ExtraArgs = @()
    )

    $overwriteValue = $Overwrite.IsPresent.ToString().ToLowerInvariant()
    $azArgs = @(
        'copy',
        $Source,
        $Target,
        '--recursive=true',
        "--overwrite=$overwriteValue",
        '--log-level=INFO'
    ) + $ExtraArgs

    & azcopy @azArgs

    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy failed for source '$Source'."
    }
}

function Convert-PrefixToLocalPath {
    param([string]$Prefix)
    return Join-Path $seedRoot ($Prefix -replace '/', '\')
}

function Get-SeedDateFolders {
    param([string]$IndicesPath)

    if (-not (Test-Path $IndicesPath)) {
        return @()
    }

    $dateDirs = Get-ChildItem -Path $IndicesPath -Directory -ErrorAction SilentlyContinue
    $dates = foreach ($dir in $dateDirs) {
        $parsed = [datetime]::MinValue
        if ([DateTime]::TryParseExact($dir.Name, 'yyyy-MM-dd', $null, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            $dir.Name
        }
    }

    if (-not $dates) {
        return @()
    }

    return $dates | Select-Object -Unique | Sort-Object -Descending | Select-Object -First $Days
}

function Invoke-AzCopyIfLocalExists {
    param([string]$Prefix)

    $localPath = Convert-PrefixToLocalPath -Prefix $Prefix
    if (Test-Path $localPath) {
        Invoke-AzCopy -Source $localPath -Target "$targetBase/$Prefix"
    } else {
        Write-Output "Skipping missing seed path: $Prefix"
    }
}

if ($Days -lt 1) {
    throw 'Days must be at least 1.'
}

Assert-Command -Name 'az'
Assert-Command -Name 'azcopy'

if (-not (Test-Path $SeedPath)) {
    throw "Seed path not found: $SeedPath"
}

if ($SubscriptionId) {
    Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

$seedRoot = (Resolve-Path $SeedPath).Path
$targetBase = "https://$StorageAccountName.blob.core.windows.net/$ContainerName"

$requiredPrefixes = @('notices', 'config')
foreach ($prefix in $requiredPrefixes) {
    $requiredPath = Convert-PrefixToLocalPath -Prefix $prefix
    if (-not (Test-Path $requiredPath)) {
        throw "Seed data missing required path: $requiredPath"
    }
    Invoke-AzCopy -Source $requiredPath -Target "$targetBase/$prefix"
}

Invoke-AzCopyIfLocalExists -Prefix 'tracking'
Invoke-AzCopyIfLocalExists -Prefix 'discovery'

$indicesPath = Convert-PrefixToLocalPath -Prefix 'indices/daily'
$dateFolders = Get-SeedDateFolders -IndicesPath $indicesPath
if (-not $dateFolders -or $dateFolders.Count -eq 0) {
    $dateFolders = 0..($Days - 1) | ForEach-Object { [DateTime]::UtcNow.AddDays(-$_).ToString('yyyy-MM-dd') }
}

foreach ($dateFolder in $dateFolders) {
    Invoke-AzCopyIfLocalExists -Prefix "indices/daily/$dateFolder"

    foreach ($source in $Sources) {
        Invoke-AzCopyIfLocalExists -Prefix "raw/$source/$dateFolder"
        Invoke-AzCopyIfLocalExists -Prefix "processed/raw/$source/$dateFolder"
    }
}

Invoke-AzCopyIfLocalExists -Prefix 'parsed'

Write-Output "Seed package imported from $seedRoot"
