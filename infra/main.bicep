// Main orchestration file for Critical Notice Ingestion Infrastructure
// Deploys: Storage Account, Key Vault, Logic Apps Consumption, Data Factory
// Target Resource Group: rg-dte-noticeapp-eus2-mx01

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Environment name (dev, test, prod)')
param environment string = 'prod'

@description('Tags to apply to all resources')
param tags object = {
  Project: 'Critical Notice Ingestion'
  Environment: environment
  ManagedBy: 'Bicep'
}

// Resource naming parameters
@description('Storage account name (must be globally unique, 3-24 lowercase alphanumeric)')
param storageAccountName string = 'stdtenoticeappeus2mx01'

@description('Key Vault name (must be globally unique, 3-24 alphanumeric and hyphens)')
param keyVaultName string = 'kv-dtenotice-eus2-mx01'

@description('Logic App name')
param logicAppName string = 'logic-dte-noticeapp-eus2-mx01'

@description('Data Factory name')
param dataFactoryName string = 'adf-dte-noticeapp-eus2-mx01'

// ============================================================================
// Module Deployments
// ============================================================================

// 1. Storage Account (deployed first - no dependencies)
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
  }
}

// 2. Microsoft Foundry (Cognitive Services for AI parsing)
module foundry 'modules/foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    location: location
    tags: tags
  }
}

// 3. Logic Apps Consumption (depends on storage and foundry)
module logicApp 'modules/logicapp.bicep' = {
  name: 'logicapp-deployment'
  params: {
    location: location
    logicAppName: logicAppName
    storageAccountName: storageAccountName
    foundryEndpoint: foundry.outputs.foundryEndpoint
    foundryApiKey: foundry.outputs.foundryApiKey
    foundryDeploymentName: foundry.outputs.deploymentName
    tags: tags
  }
  dependsOn: [
    storage
    foundry
  ]
}

// 4. Key Vault (deployed after Logic App to get managed identity and store Foundry key)
module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-deployment'
  params: {
    location: location
    keyVaultName: keyVaultName
    logicAppPrincipalId: logicApp.outputs.logicAppPrincipalId
    foundryApiKey: foundry.outputs.foundryApiKey
    tags: tags
  }
  dependsOn: [
    logicApp
    foundry
  ]
}

// 5. Data Factory
module dataFactory 'modules/datafactory.bicep' = {
  name: 'datafactory-deployment'
  params: {
    location: location
    dataFactoryName: dataFactoryName
    storageAccountId: storage.outputs.storageAccountId
    tags: tags
  }
}

// ============================================================================
// Role Assignments
// ============================================================================

// Storage Blob Data Owner role for Logic App Scanner (required for managed identity blob operations)
// Role ID: b7e6dc6d-f1e8-4753-8033-0f276bb0955b
resource scannerStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, storageAccountName, logicAppName, 'scanner', 'StorageBlobDataOwner')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: logicApp.outputs.logicAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor role for Logic App Downloader
// Role ID: ba92f5b4-2d11-453d-a403-e96b0029c9fe
resource downloaderStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, storageAccountName, logicAppName, 'downloader', 'StorageBlobDataContributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: logicApp.outputs.downloaderPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor role for Logic App Parser
resource parserStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, storageAccountName, logicAppName, 'parser', 'StorageBlobDataContributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: logicApp.outputs.parserPrincipalId
    principalType: 'ServicePrincipal'
  }
}



// Storage Blob Data Contributor role for Data Factory
resource adfStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, storageAccountName, dataFactoryName, 'StorageBlobDataContributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: dataFactory.outputs.dataFactoryPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User for Data Factory
// NOTE: This role assignment already exists in prod with a non-standard name.
// Role assignment names must be deploy-time constants, so we pin to the existing GUID to avoid
// RoleAssignmentExists failures on redeploy.
resource adfKeyVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'd01069f8-e69b-5b52-b262-7dc8ae066825'
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: dataFactory.outputs.dataFactoryPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Storage Account name')
output storageAccountName string = storage.outputs.storageAccountName

@description('Storage Account blob endpoint')
output storageBlobEndpoint string = storage.outputs.blobEndpoint

@description('Key Vault name')
output keyVaultName string = keyVault.outputs.keyVaultName

@description('Key Vault URI')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('Logic App Scanner name')
output logicAppScannerName string = logicApp.outputs.scannerLogicAppName

@description('Logic App Downloader name')
output logicAppDownloaderName string = logicApp.outputs.downloaderLogicAppName

@description('Logic App Scanner managed identity principal ID')
output logicAppPrincipalId string = logicApp.outputs.logicAppPrincipalId

@description('Logic App Downloader managed identity principal ID')
output downloaderPrincipalId string = logicApp.outputs.downloaderPrincipalId

@description('Downloader callback URL (for testing)')
output downloaderCallbackUrl string = logicApp.outputs.downloaderCallbackUrl

@description('Data Factory name')
output dataFactoryName string = dataFactory.outputs.dataFactoryName

@description('Data Factory managed identity principal ID')
output dataFactoryPrincipalId string = dataFactory.outputs.dataFactoryPrincipalId

@description('Foundry endpoint')
output foundryEndpoint string = foundry.outputs.foundryEndpoint

@description('Foundry deployment name')
output foundryDeploymentName string = foundry.outputs.deploymentName

@description('Logic App Parser name')
output logicAppParserName string = logicApp.outputs.parserLogicAppName
