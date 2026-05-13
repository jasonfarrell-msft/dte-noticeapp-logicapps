[CmdletBinding()]
param(
    [string]$SeedPath = (Join-Path $PSScriptRoot '..\seed-package'),

    [int]$DaysRequired = 10,

    [string[]]$Sources = @('enbridge', 'tceconnects')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PathExists {
    param(
        [string]$Path,
        [string]$Message
    )

    if (-not (Test-Path $Path)) {
        throw "${Message}: $Path"
    }
}

function Test-PathHasFiles {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $file = Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    return $null -ne $file
}

function Test-AnyPathHasFiles {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if (Test-PathHasFiles -Path $path) {
            return $true
        }
    }

    return $false
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

    return $dates | Select-Object -Unique | Sort-Object -Descending
}

if ($DaysRequired -lt 1) {
    throw 'DaysRequired must be at least 1.'
}

if (-not (Test-Path $SeedPath)) {
    throw "Seed path not found: $SeedPath"
}

$seedRoot = (Resolve-Path $SeedPath).Path

$noticesPath = Join-Path $seedRoot 'notices'
Assert-PathExists -Path $noticesPath -Message 'Seed data missing notices path'

if (-not (Test-PathHasFiles -Path $noticesPath)) {
    throw "No notice files found under $noticesPath."
}

foreach ($source in $Sources) {
    $sourcePath = Join-Path $noticesPath $source
    if (-not (Test-Path $sourcePath)) {
        throw "Seed data missing notices source folder: $sourcePath"
    }
    if (-not (Test-PathHasFiles -Path $sourcePath)) {
        throw "No notice files found for source '$source' under $sourcePath."
    }
}

$configPath = Join-Path $seedRoot 'config'
Assert-PathExists -Path $configPath -Message 'Seed data missing config path'

$sitesPath = Join-Path $configPath 'sites.json'
if (-not (Test-Path $sitesPath)) {
    throw "Seed data missing required config file: $sitesPath"
}

$sitesInfo = Get-Item $sitesPath
if ($sitesInfo.Length -le 0) {
    throw "config/sites.json is present but empty: $sitesPath"
}

$indicesPath = Join-Path (Join-Path $seedRoot 'indices') 'daily'
Assert-PathExists -Path $indicesPath -Message 'Seed data missing indices/daily path'

$dateFolders = Get-SeedDateFolders -IndicesPath $indicesPath
if ($dateFolders.Count -lt $DaysRequired) {
    throw "Only $($dateFolders.Count) daily index date folders found under $indicesPath. Expected at least $DaysRequired."
}

$datesToCheck = $dateFolders | Select-Object -First $DaysRequired

$rawRoot = Join-Path $seedRoot 'raw'
$processedRoot = Join-Path (Join-Path $seedRoot 'processed') 'raw'

foreach ($dateFolder in $datesToCheck) {
    $indexDatePath = Join-Path $indicesPath $dateFolder
    if (-not (Test-PathHasFiles -Path $indexDatePath)) {
        throw "Daily index folder '$dateFolder' has no files under $indexDatePath."
    }

    $rawPaths = $Sources | ForEach-Object { Join-Path (Join-Path $rawRoot $_) $dateFolder }
    $processedPaths = $Sources | ForEach-Object { Join-Path (Join-Path $processedRoot $_) $dateFolder }

    $hasRaw = Test-AnyPathHasFiles -Paths $rawPaths
    $hasProcessed = Test-AnyPathHasFiles -Paths $processedPaths

    if (-not ($hasRaw -or $hasProcessed)) {
        throw "No raw or processed/raw content found for index date '$dateFolder' in seed package."
    }
}

Write-Output "Seed package validation passed for $seedRoot."
