[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [string]$ContainerName = 'critical-notices',

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\sites.json'),

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

Assert-Command -Name 'az'

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

az storage container create `
    --name $ContainerName `
    --account-name $StorageAccountName `
    --auth-mode login `
    --only-show-errors | Out-Null

$overwriteValue = $Overwrite.IsPresent.ToString().ToLowerInvariant()

az storage blob upload `
    --account-name $StorageAccountName `
    --container-name $ContainerName `
    --name 'config/sites.json' `
    --file $ConfigPath `
    --content-type 'application/json' `
    --auth-mode login `
    --overwrite $overwriteValue `
    --only-show-errors
