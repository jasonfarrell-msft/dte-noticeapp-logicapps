[CmdletBinding()]
param(
    [string]$ScriptsPath = $PSScriptRoot,

    [string[]]$ScriptNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptsPath)) {
    throw "ScriptsPath not found: $ScriptsPath"
}

$scriptFiles = if ($ScriptNames -and $ScriptNames.Count -gt 0) {
    foreach ($name in $ScriptNames) {
        $path = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $ScriptsPath $name }
        if (-not (Test-Path $path)) {
            throw "Script not found: $path"
        }
        (Resolve-Path $path).Path
    }
} else {
    Get-ChildItem -Path $ScriptsPath -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName
}

$scriptFiles = @($scriptFiles)

if ($scriptFiles.Count -eq 0) {
    throw "No PowerShell scripts found under $ScriptsPath."
}

$parseFailures = @()

foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $parseFailures += $errors | ForEach-Object { "${scriptFile}: $($_.Message)" }
    }
}

if ($parseFailures.Count -gt 0) {
    throw "PowerShell syntax validation failed:`n$($parseFailures -join "`n")"
}

Write-Output "PowerShell script syntax validation passed for $($scriptFiles.Count) file(s)."
