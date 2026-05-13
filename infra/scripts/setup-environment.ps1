[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$Location = 'eastus2',

    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\main.parameters.json'),

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,

    [string]$DataFactoryName,

    [string]$SqlServerFqdn,

    [string]$DatabaseName = 'noticesdb',

    [ValidateSet('None', 'LocalSeed', 'Backfill')]
    [string]$SeedMode = 'None',

    [string]$SeedPath = (Join-Path $PSScriptRoot '..\seed-package'),

    [string]$SourceStorageAccountName,

    [string]$SourceResourceGroupName,

    [int]$Days = 10,

    [switch]$RunValidation,

    [switch]$SkipSqlInit,

    [switch]$AllowCallerIp,

    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PathExists {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Required script not found: $Path"
    }
}

if ($Days -lt 1) {
    throw 'Days must be at least 1.'
}

if ($SeedMode -eq 'Backfill' -and [string]::IsNullOrWhiteSpace($SourceStorageAccountName)) {
    throw 'SeedMode Backfill requires -SourceStorageAccountName.'
}

if ($SeedMode -eq 'LocalSeed' -and -not (Test-Path $SeedPath)) {
    throw "SeedMode LocalSeed requires an existing seed path: $SeedPath"
}

$deployInfraScript = Join-Path $PSScriptRoot 'deploy-infra.ps1'
$buildPackageScript = Join-Path $PSScriptRoot 'build-deployment-package.ps1'
$deployWorkflowScript = Join-Path $PSScriptRoot 'deploy-workflows-standard.ps1'
$seedConfigScript = Join-Path $PSScriptRoot 'postdeploy-seed-config.ps1'
$sqlInitScript = Join-Path $PSScriptRoot 'sql-init.ps1'
$backfillScript = Join-Path $PSScriptRoot 'backfill-blobs.ps1'
$importSeedScript = Join-Path $PSScriptRoot 'import-seed-package.ps1'
$validateRedeployScript = Join-Path $PSScriptRoot 'validate-redeploy.ps1'
$validateSeedScript = Join-Path $PSScriptRoot 'validate-seed-package.ps1'

Assert-PathExists -Path $deployInfraScript
Assert-PathExists -Path $buildPackageScript
Assert-PathExists -Path $deployWorkflowScript
Assert-PathExists -Path $seedConfigScript
if ($SqlServerFqdn -and -not $SkipSqlInit) {
    Assert-PathExists -Path $sqlInitScript
}
Assert-PathExists -Path $validateRedeployScript
Assert-PathExists -Path $ParametersFile

$subscriptionArgs = @{}
if ($SubscriptionId) {
    $subscriptionArgs.SubscriptionId = $SubscriptionId
}

$targetIpRule = $null
$sourceIpRule = $null

if ($AllowCallerIp) {
    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -UseBasicParsing).Trim()
    Write-Output "Detected public IP: $publicIp"
    
    $targetIpRule = @{
        AccountName = $StorageAccountName
        ResourceGroupName = $ResourceGroupName
        IpAddress = $publicIp
    }
    
    Write-Output "Adding IP rule to target storage: $StorageAccountName"
    az storage account network-rule add `
        --account-name $StorageAccountName `
        --resource-group $ResourceGroupName `
        --ip-address $publicIp `
        --only-show-errors | Out-Null
    
    if ($SeedMode -eq 'Backfill' -and $SourceStorageAccountName -and $SourceResourceGroupName) {
        Write-Output "Adding IP rule to source storage: $SourceStorageAccountName"
        $sourceIpRule = @{
            AccountName = $SourceStorageAccountName
            ResourceGroupName = $SourceResourceGroupName
            IpAddress = $publicIp
        }
        
        az storage account network-rule add `
            --account-name $SourceStorageAccountName `
            --resource-group $SourceResourceGroupName `
            --ip-address $publicIp `
            --only-show-errors | Out-Null
    }
    
    Start-Sleep -Seconds 15
}

try {
    & $deployInfraScript -ResourceGroupName $ResourceGroupName -Location $Location -ParametersFile $ParametersFile @subscriptionArgs

    & $buildPackageScript -Force

    & $deployWorkflowScript -ResourceGroupName $ResourceGroupName -LogicAppName $LogicAppName @subscriptionArgs

    & $seedConfigScript -StorageAccountName $StorageAccountName @subscriptionArgs

    if ($SqlServerFqdn -and -not $SkipSqlInit) {
        if ([string]::IsNullOrWhiteSpace($DataFactoryName)) {
            & $sqlInitScript -SqlServerFqdn $SqlServerFqdn -DatabaseName $DatabaseName
        } else {
            & $sqlInitScript -SqlServerFqdn $SqlServerFqdn -DatabaseName $DatabaseName -DataFactoryName $DataFactoryName
        }
    } elseif ($SkipSqlInit) {
        Write-Output 'Skipping SQL initialization (SkipSqlInit specified).'
    } else {
        Write-Output 'Skipping SQL initialization (SqlServerFqdn not supplied).'
    }

switch ($SeedMode) {
    'LocalSeed' {
        Assert-PathExists -Path $importSeedScript
        Assert-PathExists -Path $validateSeedScript

        if ($RunValidation) {
            & $validateSeedScript -SeedPath $SeedPath -DaysRequired $Days
        }

        $importArgs = @{
            StorageAccountName = $StorageAccountName
            SeedPath = $SeedPath
            Days = $Days
        }
        if ($SubscriptionId) {
            $importArgs.SubscriptionId = $SubscriptionId
        }

        & $importSeedScript @importArgs
    }
    'Backfill' {
        Assert-PathExists -Path $backfillScript

        $backfillArgs = @{
            SourceStorageAccountName = $SourceStorageAccountName
            TargetStorageAccountName = $StorageAccountName
            TargetResourceGroupName = $ResourceGroupName
            Days = $Days
        }
        if ($SourceResourceGroupName) {
            $backfillArgs.SourceResourceGroupName = $SourceResourceGroupName
        }
        if ($SubscriptionId) {
            $backfillArgs.SubscriptionId = $SubscriptionId
        }

        & $backfillScript @backfillArgs
    }
    Default {
        Write-Output 'SeedMode None selected; skipping data seed/backfill.'
    }
}

    if ($RunValidation) {
        $validateArgs = @{
            ResourceGroupName = $ResourceGroupName
            LogicAppName = $LogicAppName
            StorageAccountName = $StorageAccountName
            DaysRequired = $Days
        }
        if (-not [string]::IsNullOrWhiteSpace($DataFactoryName)) {
            $validateArgs.DataFactoryName = $DataFactoryName
        }
        if ($SqlServerFqdn) {
            $validateArgs.SqlServerFqdn = $SqlServerFqdn
            $validateArgs.DatabaseName = $DatabaseName
        }
        if ($SubscriptionId) {
            $validateArgs.SubscriptionId = $SubscriptionId
        }

        & $validateRedeployScript @validateArgs
    }
} finally {
    if ($AllowCallerIp) {
        if ($targetIpRule) {
            Write-Output "Removing IP rule from target storage: $($targetIpRule.AccountName)"
            az storage account network-rule remove `
                --account-name $targetIpRule.AccountName `
                --resource-group $targetIpRule.ResourceGroupName `
                --ip-address $targetIpRule.IpAddress `
                --only-show-errors | Out-Null
        }
        
        if ($sourceIpRule) {
            Write-Output "Removing IP rule from source storage: $($sourceIpRule.AccountName)"
            az storage account network-rule remove `
                --account-name $sourceIpRule.AccountName `
                --resource-group $sourceIpRule.ResourceGroupName `
                --ip-address $sourceIpRule.IpAddress `
                --only-show-errors | Out-Null
        }
    }
}
