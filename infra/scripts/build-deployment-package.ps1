[CmdletBinding()]
param(
    [string]$WorkflowSourceFolder = (Join-Path $PSScriptRoot '..\workflows'),

    [string]$PackageFolder = (Join-Path $PSScriptRoot '..\deployment-package'),

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\deployment-package.zip'),

    [string[]]$WorkflowNames = @('scanner', 'downloader', 'parser'),

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackageFolder)) {
    throw "Deployment package folder not found: $PackageFolder"
}

foreach ($workflowName in $WorkflowNames) {
    $sourceWorkflow = Join-Path $WorkflowSourceFolder "$workflowName.json"
    $targetWorkflowFolder = Join-Path $PackageFolder $workflowName
    $targetWorkflow = Join-Path $targetWorkflowFolder 'workflow.json'

    if (-not (Test-Path $sourceWorkflow)) {
        throw "Workflow source not found: $sourceWorkflow"
    }

    if (-not (Test-Path $targetWorkflowFolder)) {
        New-Item -ItemType Directory -Path $targetWorkflowFolder | Out-Null
    }

    Copy-Item -Path $sourceWorkflow -Destination $targetWorkflow -Force
}

if (Test-Path $OutputPath) {
    if ($Force) {
        Remove-Item -Path $OutputPath -Force
    } else {
        throw "Package already exists: $OutputPath. Use -Force to overwrite."
    }
}

Compress-Archive -Path (Join-Path $PackageFolder '*') -DestinationPath $OutputPath -Force

Write-Output "Created package: $OutputPath"
