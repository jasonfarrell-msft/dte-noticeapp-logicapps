[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$Location = 'eastus2',

    [string]$TemplateFile = (Join-Path $PSScriptRoot '..\main.bicep'),

    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\main.parameters.json'),

    [string]$DeploymentName = 'main',

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

if (-not (Test-Path $TemplateFile)) {
    throw "Template file not found: $TemplateFile"
}

if (-not (Test-Path $ParametersFile)) {
    throw "Parameters file not found: $ParametersFile"
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

az group create --name $ResourceGroupName --location $Location --only-show-errors | Out-Null

az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroupName `
    --template-file $TemplateFile `
    --parameters $ParametersFile `
    --only-show-errors
