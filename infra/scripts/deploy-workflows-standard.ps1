[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,

    [string]$PackagePath = (Join-Path $PSScriptRoot '..\deployment-package.zip'),

    [switch]$BuildPackage,

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

if ($BuildPackage) {
    $buildScript = Join-Path $PSScriptRoot 'build-deployment-package.ps1'
    & $buildScript -OutputPath $PackagePath -Force
}

if (-not (Test-Path $PackagePath)) {
    throw "Deployment package not found: $PackagePath. Run build-deployment-package.ps1 first."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

az logicapp deployment source config-zip `
    --name $LogicAppName `
    --resource-group $ResourceGroupName `
    --src $PackagePath `
    --only-show-errors
