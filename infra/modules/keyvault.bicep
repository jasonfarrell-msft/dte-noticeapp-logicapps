// Azure Key Vault for secrets management
// Stores storage connection strings, API keys, and credentials
// Supports VNet isolation with service endpoints

@description('Location for the Key Vault')
param location string

@description('Name of the Key Vault')
param keyVaultName string

@description('Tags to apply to resources')
param tags object = {}

@description('Principal ID for Logic App managed identity (for access policy)')
param logicAppPrincipalId string = ''

@description('Storage account connection string to store as secret')
@secure()
param storageConnectionString string = ''

@description('Microsoft Foundry API key to store as secret')
@secure()
param foundryApiKey string = ''

@description('Enable VNet restrictions (deny public access)')
param enableVnetRestrictions bool = false

@description('Subnet IDs to allow access (when VNet restrictions enabled)')
param allowedSubnetIds array = []

// Build virtual network rules from allowed subnet IDs
var virtualNetworkRules = [for subnetId in allowedSubnetIds: {
  id: subnetId
  ignoreMissingVnetServiceEndpoint: false
}]

// Key Vault resource
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enableRbacAuthorization: true
    publicNetworkAccess: enableVnetRestrictions ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: enableVnetRestrictions ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
      virtualNetworkRules: enableVnetRestrictions ? virtualNetworkRules : []
      ipRules: []
    }
  }
}

// Store storage connection string as secret (if provided)
resource storageConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(storageConnectionString)) {
  parent: keyVault
  name: 'StorageConnectionString'
  properties: {
    value: storageConnectionString
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

// Store Foundry API key as secret (if provided)
resource foundryApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(foundryApiKey)) {
  parent: keyVault
  name: 'FoundryApiKey'
  properties: {
    value: foundryApiKey
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

// Key Vault Secrets User role assignment for Logic App
// Role ID: 4633458b-17de-408a-b874-0445c86b69e6 (Key Vault Secrets User)
resource logicAppSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(logicAppPrincipalId)) {
  name: guid(keyVault.id, logicAppPrincipalId, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
@description('Key Vault resource ID')
output keyVaultId string = keyVault.id

@description('Key Vault name')
output keyVaultName string = keyVault.name

@description('Key Vault URI')
output keyVaultUri string = keyVault.properties.vaultUri
