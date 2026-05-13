[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceStorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$TargetStorageAccountName,

    [string]$ContainerName = 'critical-notices',

    [int]$Days = 10,

    [string[]]$Sources = @('enbridge', 'tceconnects'),

    [string]$SourceResourceGroupName,

    [string]$TargetResourceGroupName,

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

function Invoke-AzCopy {
    param(
        [string]$Source,
        [string]$Target,
        [string[]]$ExtraArgs = @()
    )

    $args = @(
        'copy',
        $Source,
        $Target,
        '--recursive=true',
        '--overwrite=false',
        '--log-level=INFO'
    ) + $ExtraArgs

    & azcopy @args

    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy failed for source '$Source'."
    }
}

function Invoke-AzCopyIfPrefixExists {
    param(
        [string]$Prefix
    )

    if (Test-BlobPrefixExists -AccountName $SourceStorageAccountName -Container $ContainerName -Prefix "$Prefix/") {
        Invoke-AzCopy -Source "$sourceBase/$Prefix" -Target "$targetBase/$Prefix"
    } else {
        Write-Output "Skipping missing source prefix: $Prefix"
    }
}

function Test-BlobPrefixExists {
    param(
        [string]$AccountName,
        [string]$Container,
        [string]$Prefix
    )

    $result = az storage blob list `
        --account-name $AccountName `
        --container-name $Container `
        --prefix $Prefix `
        --auth-mode login `
        --only-show-errors `
        --query "[0].name" `
        -o tsv

    return -not [string]::IsNullOrWhiteSpace($result)
}

if ($Days -lt 1) {
    throw 'Days must be at least 1.'
}

Assert-Command -Name 'az'
Assert-Command -Name 'azcopy'

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

if ($SourceResourceGroupName) {
    az storage account show --name $SourceStorageAccountName --resource-group $SourceResourceGroupName --only-show-errors | Out-Null
}

if ($TargetResourceGroupName) {
    az storage account show --name $TargetStorageAccountName --resource-group $TargetResourceGroupName --only-show-errors | Out-Null
}

$cutoffUtc = [DateTime]::UtcNow.AddDays(-$Days)
$cutoffIso = $cutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

$sourceBase = "https://$SourceStorageAccountName.blob.core.windows.net/$ContainerName"
$targetBase = "https://$TargetStorageAccountName.blob.core.windows.net/$ContainerName"

Invoke-AzCopy -Source "$sourceBase/notices" -Target "$targetBase/notices"
Invoke-AzCopy -Source "$sourceBase/config" -Target "$targetBase/config"
Invoke-AzCopyIfPrefixExists -Prefix 'tracking'
Invoke-AzCopyIfPrefixExists -Prefix 'discovery'

for ($offset = 0; $offset -lt $Days; $offset++) {
    $dateFolder = [DateTime]::UtcNow.AddDays(-$offset).ToString('yyyy-MM-dd')

    Invoke-AzCopyIfPrefixExists -Prefix "indices/daily/$dateFolder"

    foreach ($source in $Sources) {
        Invoke-AzCopyIfPrefixExists -Prefix "raw/$source/$dateFolder"
        Invoke-AzCopyIfPrefixExists -Prefix "processed/raw/$source/$dateFolder"
    }
}

if (Test-BlobPrefixExists -AccountName $SourceStorageAccountName -Container $ContainerName -Prefix 'parsed/') {
    Invoke-AzCopy -Source "$sourceBase/parsed" -Target "$targetBase/parsed" -ExtraArgs @("--include-after=$cutoffIso")
} else {
    Write-Output 'Skipping missing source prefix: parsed'
}
