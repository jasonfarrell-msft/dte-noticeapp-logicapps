// Azure Logic Apps Standard (WS1) with VNet Integration
// Single Logic App Standard hosting multiple workflows (scanner, downloader, parser)
// Workflows are deployed separately via zip deploy

@description('Location for resources')
param location string

@description('Logic App Standard name')
param logicAppName string = 'logic-dte-noticeapp-eus2-mx01'

@description('App Service Plan name')
param appServicePlanName string = 'asp-dte-noticeapp-eus2-mx01'

@description('Tags to apply to resources')
param tags object = {}

@description('Storage account name for Logic App internal state and business data')
param storageAccountName string

@description('Storage account connection string for AzureWebJobsStorage')
@secure()
param storageConnectionString string

@description('Microsoft Foundry endpoint URL')
param foundryEndpoint string

@description('Microsoft Foundry deployment name')
param foundryDeploymentName string

@description('VNet integration subnet ID')
param vnetIntegrationSubnetId string

@description('Key Vault URI for secrets reference')
param keyVaultUri string

// ============================================================================
// App Service Plan (Workflow Standard WS1)
// ============================================================================
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    maximumElasticWorkerCount: 20
    reserved: false
  }
}

// ============================================================================
// Logic App Standard
// ============================================================================
resource logicAppStandard 'Microsoft.Web/sites@2023-12-01' = {
  name: logicAppName
  location: location
  tags: union(tags, { Service: 'CriticalNotice-Workflows' })
  kind: 'workflowapp,functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    virtualNetworkSubnetId: vnetIntegrationSubnetId
    vnetRouteAllEnabled: true
    siteConfig: {
      netFrameworkVersion: 'v6.0'
      ftpsState: 'Disabled'
      use32BitWorkerProcess: false
      cors: {
        allowedOrigins: []
      }
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~18'
        }
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(logicAppName)
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'APP_KIND'
          value: 'workflowapp'
        }
        // Custom app settings for workflows
        {
          name: 'StorageAccountName'
          value: storageAccountName
        }
        {
          name: 'FoundryEndpoint'
          value: foundryEndpoint
        }
        {
          name: 'FoundryDeploymentName'
          value: foundryDeploymentName
        }
        {
          name: 'KeyVaultUri'
          value: keyVaultUri
        }
        // VNet integration settings
        {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: '1'
        }
        {
          name: 'WEBSITE_CONTENTOVERVNET'
          value: '1'
        }
      ]
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Logic App Standard resource ID')
output logicAppId string = logicAppStandard.id

@description('Logic App Standard name')
output logicAppName string = logicAppStandard.name

@description('Logic App Standard managed identity principal ID')
output logicAppPrincipalId string = logicAppStandard.identity.principalId

@description('Logic App Standard default hostname')
output logicAppHostname string = logicAppStandard.properties.defaultHostName

@description('App Service Plan ID')
output appServicePlanId string = appServicePlan.id

@description('App Service Plan name')
output appServicePlanName string = appServicePlan.name
