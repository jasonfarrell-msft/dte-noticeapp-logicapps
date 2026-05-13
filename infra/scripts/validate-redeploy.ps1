[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [string]$DataFactoryName,

    [string]$SqlServerFqdn,

    [string]$DatabaseName = 'noticesdb',

    [string]$ContainerName = 'critical-notices',

    [int]$DaysRequired = 10,

    [string[]]$WorkflowNames = @('scanner', 'downloader', 'parser'),

    [string[]]$Sources = @('enbridge', 'tceconnects'),

    [string]$TemplateFile = (Join-Path $PSScriptRoot '..\main.bicep'),

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

function Test-AnyBlobPrefix {
    param(
        [string]$AccountName,
        [string]$Container,
        [string[]]$Prefixes
    )

    foreach ($prefix in $Prefixes) {
        if (Test-BlobPrefixExists -AccountName $AccountName -Container $Container -Prefix $prefix) {
            return $true
        }
    }

    return $false
}

Assert-Command -Name 'az'

if (-not (Test-Path $TemplateFile)) {
    throw "Template file not found: $TemplateFile"
}

Invoke-Az -AzArgs @('account', 'show', '--query', 'id', '-o', 'tsv') | Out-Null

if ($SubscriptionId) {
    Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

Invoke-Az -AzArgs @('bicep', 'build', '--file', $TemplateFile, '--stdout') | Out-Null

Invoke-Az -AzArgs @('group', 'show', '--name', $ResourceGroupName) | Out-Null

$storageAccount = Invoke-Az -AzArgs @(
    'storage', 'account', 'show',
    '--name', $StorageAccountName,
    '--resource-group', $ResourceGroupName
) | ConvertFrom-Json

if ($storageAccount.tags.SecurityControl -ne 'Ignore') {
    throw "Storage account '$StorageAccountName' must have tag SecurityControl=Ignore."
}

if ($storageAccount.allowBlobPublicAccess -ne $false) {
    throw "Storage account '$StorageAccountName' must have anonymous blob public access disabled."
}

if ($storageAccount.publicNetworkAccess -ne 'Enabled') {
    throw "Storage account '$StorageAccountName' must have public network access enabled."
}

if ($storageAccount.networkRuleSet.defaultAction -ne 'Allow') {
    throw "Storage account '$StorageAccountName' must allow data-plane access from all networks (networkRuleSet.defaultAction=Allow)."
}

Invoke-Az -AzArgs @(
    'resource', 'show',
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Web/sites',
    '--name', $LogicAppName
) | Out-Null

if (-not [string]::IsNullOrWhiteSpace($DataFactoryName)) {
    Invoke-Az -AzArgs @(
        'datafactory', 'factory', 'show',
        '--name', $DataFactoryName,
        '--resource-group', $ResourceGroupName
    ) | Out-Null
}

$missingTagResources = @(Invoke-Az -AzArgs @(
    'resource', 'list',
    '--resource-group', $ResourceGroupName,
    '--query', "[?type!='Microsoft.Authorization/roleAssignments' && type!='Microsoft.EventGrid/systemTopics' && type!='Microsoft.Sql/servers/databases' && tags.SecurityControl!='Ignore'].{name:name,type:type}",
    '-o', 'json'
) | ConvertFrom-Json)

if ($missingTagResources.Count -gt 0) {
    $details = ($missingTagResources | ForEach-Object { "$($_.name) ($($_.type))" }) -join '; '
    throw "SecurityControl tag missing or incorrect for: $details"
}

$containerExists = Invoke-Az -AzArgs @(
    'storage', 'container', 'exists',
    '--account-name', $StorageAccountName,
    '--name', $ContainerName,
    '--auth-mode', 'login',
    '--query', 'exists',
    '-o', 'tsv'
)

if ($containerExists -ne 'true') {
    throw "Storage container '$ContainerName' not found in account '$StorageAccountName'."
}

$configBlobExists = Invoke-Az -AzArgs @(
    'storage', 'blob', 'exists',
    '--account-name', $StorageAccountName,
    '--container-name', $ContainerName,
    '--name', 'config/sites.json',
    '--auth-mode', 'login',
    '--query', 'exists',
    '-o', 'tsv'
)

if ($configBlobExists -ne 'true') {
    throw "config/sites.json is missing from '$ContainerName'. Run postdeploy-seed-config.ps1."
}

$configSize = Invoke-Az -AzArgs @(
    'storage', 'blob', 'show',
    '--account-name', $StorageAccountName,
    '--container-name', $ContainerName,
    '--name', 'config/sites.json',
    '--auth-mode', 'login',
    '--query', 'properties.contentLength',
    '-o', 'tsv'
)

if ([int]$configSize -le 0) {
    throw "config/sites.json is present but empty. Re-seed configuration."
}

foreach ($workflowName in $WorkflowNames) {
    $workflowUri = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Web/sites/{2}/workflows/{3}?api-version=2022-03-01" -f (
        (Invoke-Az -AzArgs @('account', 'show', '--query', 'id', '-o', 'tsv')).Trim(),
        $ResourceGroupName, $LogicAppName, $workflowName
    )
    $workflowJson = Invoke-Az -AzArgs @('rest', '--method', 'GET', '--uri', $workflowUri) | ConvertFrom-Json
    $workflowState = $workflowJson.properties.flowState

    if ([string]::IsNullOrWhiteSpace($workflowState)) {
        throw "Workflow '$workflowName' not found in Logic App '$LogicAppName'."
    }

    if ($workflowState -ne 'Enabled') {
        throw "Workflow '$workflowName' is not enabled (state=$workflowState)."
    }
}

$indexNames = Invoke-Az -AzArgs @(
    'storage', 'blob', 'list',
    '--account-name', $StorageAccountName,
    '--container-name', $ContainerName,
    '--prefix', 'indices/daily/',
    '--auth-mode', 'login',
    '--query', '[].name',
    '-o', 'tsv'
)

$indexList = $indexNames -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if ($indexList.Count -eq 0) {
    throw "No daily index blobs found under indices/daily/. Backfill likely failed."
}

$dateFolders = $indexList `
    | ForEach-Object { ($_ -split '/')[2] } `
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } `
    | Select-Object -Unique

if ($dateFolders.Count -lt $DaysRequired) {
    throw "Only $($dateFolders.Count) daily index dates found. Expected at least $DaysRequired."
}

$datesToCheck = $dateFolders | Sort-Object -Descending | Select-Object -First $DaysRequired

foreach ($dateFolder in $datesToCheck) {
    $rawPrefixes = $Sources | ForEach-Object { "raw/$($_)/$dateFolder/" }
    $processedPrefixes = $Sources | ForEach-Object { "processed/raw/$($_)/$dateFolder/" }

    $hasRaw = Test-AnyBlobPrefix -AccountName $StorageAccountName -Container $ContainerName -Prefixes $rawPrefixes
    $hasProcessed = Test-AnyBlobPrefix -AccountName $StorageAccountName -Container $ContainerName -Prefixes $processedPrefixes

    if (-not ($hasRaw -or $hasProcessed)) {
        throw "No raw or processed/raw blobs found for index date '$dateFolder'."
    }
}

foreach ($source in $Sources) {
    if (-not (Test-BlobPrefixExists -AccountName $StorageAccountName -Container $ContainerName -Prefix "notices/$source/")) {
        throw "No notice blobs found for source '$source'. Ensure notices/** is copied to prevent scanner backfill flood."
    }
}

if (-not (Test-BlobPrefixExists -AccountName $StorageAccountName -Container $ContainerName -Prefix 'parsed/')) {
    throw "No parsed outputs found under parsed/. Parser may not be writing results."
}

if (-not (Test-BlobPrefixExists -AccountName $StorageAccountName -Container $ContainerName -Prefix 'processed/raw/')) {
    throw "No processed/raw outputs found. Parser may not be moving raw HTML."
}

if (-not [string]::IsNullOrWhiteSpace($DataFactoryName)) {
    Invoke-Az -AzArgs @(
        'datafactory', 'pipeline', 'show',
        '--factory-name', $DataFactoryName,
        '--resource-group', $ResourceGroupName,
        '--name', 'LandParsedToSql'
    ) | Out-Null

    Invoke-Az -AzArgs @(
        'datafactory', 'pipeline', 'show',
        '--factory-name', $DataFactoryName,
        '--resource-group', $ResourceGroupName,
        '--name', 'IngestToFabric'
    ) | Out-Null

    Invoke-Az -AzArgs @(
        'datafactory', 'linked-service', 'show',
        '--factory-name', $DataFactoryName,
        '--resource-group', $ResourceGroupName,
        '--name', 'AzureBlobStorage_ManagedIdentity'
    ) | Out-Null

    Invoke-Az -AzArgs @(
        'datafactory', 'linked-service', 'show',
        '--factory-name', $DataFactoryName,
        '--resource-group', $ResourceGroupName,
        '--name', 'AzureSqlDatabase_ManagedIdentity'
    ) | Out-Null
} else {
    Write-Output 'Skipping Data Factory validation (DataFactoryName not supplied).'
}

if ($SqlServerFqdn) {
    Assert-Command -Name 'sqlcmd'

    function Invoke-SqlQuery {
        param([string]$Query)
        $result = sqlcmd -S $SqlServerFqdn -d $DatabaseName -G -b -h -1 -W -Q $Query
        if ($LASTEXITCODE -ne 0) {
            throw "sqlcmd failed for query: $Query"
        }
        return $result
    }

    $tableNames = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.tables WHERE name IN ('notices','notice_locations');"
    $tableList = $tableNames -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not ($tableList -contains 'notices' -and $tableList -contains 'notice_locations')) {
        throw 'SQL tables dbo.notices and dbo.notice_locations are required but missing.'
    }

    $expectedNoticesColumns = @('source','pipeline','noticeId','postedDate','rawBlobPath','parsedAt','foundryModel','tokensUsed','ingestedAt')
    $noticesColumns = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.notices');"
    $noticesColumnList = $noticesColumns -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $missingNoticesColumns = $expectedNoticesColumns | Where-Object { $_ -notin $noticesColumnList }
    if ($missingNoticesColumns.Count -gt 0) {
        throw "dbo.notices is missing expected columns: $($missingNoticesColumns -join ', ')."
    }

    $expectedLocationsColumns = @('source','pipeline','noticeId','location')
    $locationsColumns = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.notice_locations');"
    $locationsColumnList = $locationsColumns -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $missingLocationColumns = $expectedLocationsColumns | Where-Object { $_ -notin $locationsColumnList }
    if ($missingLocationColumns.Count -gt 0) {
        throw "dbo.notice_locations is missing expected columns: $($missingLocationColumns -join ', ')."
    }

    Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT TOP (1) source, pipeline, noticeId, postedDate, parsedAt FROM dbo.notices;" | Out-Null
} else {
    Write-Output 'Skipping SQL validation (SqlServerFqdn not supplied).'
}

Write-Output 'Redeploy validation checks passed.'
