[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [string]$ContainerName = 'critical-notices',

    [int]$Days = 10,

    [string[]]$Sources = @('enbridge', 'tceconnects'),

    [string]$SeedPath = (Join-Path $PSScriptRoot '..\seed-package'),

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

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-AzCopy {
    param(
        [string]$Source,
        [string]$Target,
        [string[]]$ExtraArgs = @()
    )

    $azArgs = @(
        'copy',
        $Source,
        $Target,
        '--recursive=true',
        '--overwrite=ifSourceNewer',
        '--log-level=INFO'
    ) + $ExtraArgs

    & azcopy @azArgs

    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy failed for source '$Source'."
    }
}

function Test-BlobPrefixExists {
    param(
        [string]$AccountName,
        [string]$Container,
        [string]$Prefix
    )

    $result = Invoke-Az -AzArgs @(
        'storage', 'blob', 'list',
        '--account-name', $AccountName,
        '--container-name', $Container,
        '--prefix', $Prefix,
        '--auth-mode', 'login',
        '--query', '[0].name',
        '-o', 'tsv'
    )

    return -not [string]::IsNullOrWhiteSpace($result)
}

function Get-RecentDateFolders {
    param([string]$Prefix)

    $names = Invoke-Az -AzArgs @(
        'storage', 'blob', 'list',
        '--account-name', $StorageAccountName,
        '--container-name', $ContainerName,
        '--prefix', $Prefix,
        '--auth-mode', 'login',
        '--query', '[].name',
        '-o', 'tsv'
    )

    $entries = $names -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $dates = foreach ($entry in $entries) {
        $parts = $entry -split '/'
        if ($parts.Length -ge 3) {
            $candidate = $parts[2]
            $parsed = [datetime]::MinValue
            if ([DateTime]::TryParseExact($candidate, 'yyyy-MM-dd', $null, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
                $candidate
            }
        }
    }

    if (-not $dates) {
        return @()
    }

    return $dates | Select-Object -Unique | Sort-Object -Descending | Select-Object -First $Days
}

function Convert-PrefixToLocalPath {
    param([string]$Prefix)
    return Join-Path $seedRoot ($Prefix -replace '/', '\')
}

function Invoke-AzCopyIfPrefixExists {
    param([string]$Prefix)
    if (Test-BlobPrefixExists -AccountName $StorageAccountName -Container $ContainerName -Prefix "$Prefix/") {
        # AzCopy strips everything up to (not including) the last path segment of the source URL,
        # so for multi-segment prefixes we must target the parent directory so the full path is
        # reconstructed correctly at the destination (e.g. indices/daily/2026-04-18 → .../indices/daily/).
        $parts = $Prefix -split '/'
        if ($parts.Count -gt 1) {
            $parentRelative = ($parts[0..($parts.Count - 2)] -join '\')
            $target = Join-Path $seedRoot $parentRelative
            Ensure-Directory -Path $target
        } else {
            $target = $seedRoot
        }
        Invoke-AzCopy -Source "$sourceBase/$Prefix" -Target $target
    } else {
        Write-Output "Skipping missing source prefix: $Prefix"
    }
}

if ($Days -lt 1) {
    throw 'Days must be at least 1.'
}

Assert-Command -Name 'az'
Assert-Command -Name 'azcopy'

if ($SubscriptionId) {
    Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

Ensure-Directory -Path $SeedPath
$seedRoot = (Resolve-Path $SeedPath).Path

$sourceBase = "https://$StorageAccountName.blob.core.windows.net/$ContainerName"

Invoke-AzCopy -Source "$sourceBase/notices" -Target $seedRoot
Invoke-AzCopy -Source "$sourceBase/config" -Target $seedRoot
Invoke-AzCopyIfPrefixExists -Prefix 'tracking'
Invoke-AzCopyIfPrefixExists -Prefix 'discovery'

$dateFolders = Get-RecentDateFolders -Prefix 'indices/daily/'
if (-not $dateFolders -or $dateFolders.Count -eq 0) {
    $dateFolders = 0..($Days - 1) | ForEach-Object { [DateTime]::UtcNow.AddDays(-$_).ToString('yyyy-MM-dd') }
}

foreach ($dateFolder in $dateFolders) {
    Invoke-AzCopyIfPrefixExists -Prefix "indices/daily/$dateFolder"

    foreach ($source in $Sources) {
        Invoke-AzCopyIfPrefixExists -Prefix "raw/$source/$dateFolder"
        Invoke-AzCopyIfPrefixExists -Prefix "processed/raw/$source/$dateFolder"
    }
}

Invoke-AzCopyIfPrefixExists -Prefix 'parsed'
Invoke-AzCopyIfPrefixExists -Prefix 'failed-parsing'
Invoke-AzCopyIfPrefixExists -Prefix 'metadata'
Invoke-AzCopyIfPrefixExists -Prefix 'raw-html'

Write-Output "Seed package exported to $seedRoot"
