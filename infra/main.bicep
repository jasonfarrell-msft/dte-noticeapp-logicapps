// Main orchestration file for Critical Notice Ingestion Infrastructure
// Deploys: VNet, Storage Account, Key Vault, Logic Apps Standard (VNet-isolated), Data Factory
// Target Resource Group: rg-dte-noticeapp-eus2-mx01
// Architecture: VNet-isolated with private endpoints (~$180/mo)

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
  SecurityControl: 'Ignore'
}

// Resource naming parameters
@description('Storage account name (must be globally unique, 3-24 lowercase alphanumeric)')
param storageAccountName string = 'stdtenoticeappeus2mx01'

@description('Key Vault name (must be globally unique, 3-24 alphanumeric and hyphens)')
param keyVaultName string = 'kv-dtenotice-eus2-mx01'

@description('Logic App Standard name')
param logicAppName string = 'logic-dte-noticeapp-eus2-mx01'

@description('App Service Plan name')
param appServicePlanName string = 'asp-dte-noticeapp-eus2-mx01'

@description('VNet name')
param vnetName string = 'vnet-dte-noticeapp-eus2-mx01'

@description('Data Factory name')
param dataFactoryName string = 'adf-dte-noticeapp-eus2-mx01'

@description('Foundry account name')
param foundryAccountName string = 'cog-dte-noticeapp-eus2-mx01'

// ============================================================================
// Module Deployments
// ============================================================================

// 1. Virtual Network (deployed first - foundation for VNet integration)
module vnet 'modules/vnet.bicep' = {
  name: 'vnet-deployment'
  params: {
    location: location
    vnetName: vnetName
    tags: tags
  }
}

// 2. Storage Account (with VNet restrictions - allow service endpoints)
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
    // VNet isolation parameters
    enableVnetRestrictions: true
    allowedSubnetIds: [
      vnet.outputs.logicAppsSubnetId
    ]
  }
  dependsOn: [
    vnet
  ]
}

// 3. Microsoft Foundry (Cognitive Services for AI parsing - with private endpoint config)
module foundry 'modules/foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    location: location
    tags: tags
    foundryAccountName: foundryAccountName
    // Will be restricted to private endpoint after PE deployment
  }
}

// 4. Key Vault (with VNet restrictions)
module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-deployment'
  params: {
    location: location
    keyVaultName: keyVaultName
    foundryApiKey: foundry.outputs.foundryApiKey
    tags: tags
    // VNet isolation parameters
    enableVnetRestrictions: true
    allowedSubnetIds: [
      vnet.outputs.logicAppsSubnetId
    ]
  }
  dependsOn: [
    vnet
    foundry
  ]
}

// 5. Private Endpoints (after VNet, Storage, Foundry, Key Vault exist)
module privateEndpoints 'modules/private-endpoints.bicep' = {
  name: 'private-endpoints-deployment'
  params: {
    location: location
    tags: tags
    vnetId: vnet.outputs.vnetId
    privateEndpointsSubnetId: vnet.outputs.privateEndpointsSubnetId
    storageAccountId: storage.outputs.storageAccountId
    storageAccountName: storageAccountName
    foundryResourceId: foundry.outputs.foundryResourceId
    foundryAccountName: foundryAccountName
    keyVaultId: keyVault.outputs.keyVaultId
    keyVaultName: keyVaultName
  }
  dependsOn: [
    vnet
    storage
    foundry
    keyVault
  ]
}

// 6. Logic Apps Standard (VNet-integrated, depends on everything above)
module logicAppStandard 'modules/logicapp-standard.bicep' = {
  name: 'logicapp-standard-deployment'
  params: {
    location: location
    logicAppName: logicAppName
    appServicePlanName: appServicePlanName
    storageAccountName: storageAccountName
    storageConnectionString: storage.outputs.storageConnectionString
    foundryEndpoint: foundry.outputs.foundryEndpoint
    foundryDeploymentName: foundry.outputs.deploymentName
    vnetIntegrationSubnetId: vnet.outputs.logicAppsSubnetId
    keyVaultUri: keyVault.outputs.keyVaultUri
    tags: tags
  }
  dependsOn: [
    vnet
    storage
    foundry
    keyVault
    privateEndpoints
  ]
}

// 7. Data Factory (keeps public access for now - ADF doesn't fully support PE in all configs)
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

// Storage Blob Data Owner role for Logic App Standard (required for managed identity blob operations)
// Role ID: b7e6dc6d-f1e8-4753-8033-0f276bb0955b
// Note: Using 'standard' suffix to avoid conflict with old Consumption logic app role assignments
resource logicAppStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, storageAccountName, logicAppName, 'standard', 'StorageBlobDataOwner')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: logicAppStandard.outputs.logicAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User for Logic App Standard
// Role ID: 4633458b-17de-408a-b874-0445c86b69e6
// Pinned to existing GUID from previous deployment
resource logicAppKeyVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: '8ab80e73-28e2-5c85-82f3-a79179c91441'
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: logicAppStandard.outputs.logicAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Cognitive Services User role for Logic App Standard (to call Foundry)
// Role ID: a97b65f3-24c7-4388-baec-2e87135dc908
// Pinned to existing GUID from previous deployment
resource logicAppFoundryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'fdb87f43-7023-5260-92b4-53db918b6848'
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
    principalId: logicAppStandard.outputs.logicAppPrincipalId
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

@description('VNet name')
output vnetName string = vnet.outputs.vnetName

@description('VNet ID')
output vnetId string = vnet.outputs.vnetId

@description('Storage Account name')
output storageAccountName string = storage.outputs.storageAccountName

@description('Storage Account blob endpoint')
output storageBlobEndpoint string = storage.outputs.blobEndpoint

@description('Key Vault name')
output keyVaultName string = keyVault.outputs.keyVaultName

@description('Key Vault URI')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('Logic App Standard name')
output logicAppStandardName string = logicAppStandard.outputs.logicAppName

@description('Logic App Standard hostname')
output logicAppStandardHostname string = logicAppStandard.outputs.logicAppHostname

@description('Logic App Standard managed identity principal ID')
output logicAppPrincipalId string = logicAppStandard.outputs.logicAppPrincipalId

@description('App Service Plan name')
output appServicePlanName string = logicAppStandard.outputs.appServicePlanName

@description('Data Factory name')
output dataFactoryName string = dataFactory.outputs.dataFactoryName

@description('Data Factory managed identity principal ID')
output dataFactoryPrincipalId string = dataFactory.outputs.dataFactoryPrincipalId

@description('Foundry endpoint')
output foundryEndpoint string = foundry.outputs.foundryEndpoint

@description('Foundry deployment name')
output foundryDeploymentName string = foundry.outputs.deploymentName
