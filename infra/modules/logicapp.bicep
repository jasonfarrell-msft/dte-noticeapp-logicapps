// Azure Logic Apps (Consumption tier)
// Multi-site critical notice ingestion workflows
// - Scanner: Polls Enbridge (HTML) + TCeConnects (JSON API) every 15 minutes
// - Downloader: Downloads individual notices from any source

@description('Location for resources')
param location string

@description('Base name for Logic App resources')
param logicAppName string

@description('Tags to apply to resources')
param tags object = {}

@description('Storage account name for blob operations')
param storageAccountName string

@description('Microsoft Foundry endpoint URL')
param foundryEndpoint string

@description('Microsoft Foundry API key')
@secure()
param foundryApiKey string

@description('Microsoft Foundry deployment name')
param foundryDeploymentName string

// Load workflow definitions from JSON files (multi-site versions)
var scannerDefinition = loadJsonContent('../workflows/scanner-multisite.json')
var downloaderDefinition = loadJsonContent('../workflows/downloader-multisite.json')
var parserDefinition = loadJsonContent('../workflows/parser-multisite.json')

// ============================================================================
// Downloader (deployed first - Scanner needs its callback URL)
// ============================================================================
resource downloaderLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${logicAppName}-downloader'
  location: location
  tags: union(tags, { Workflow: 'CriticalNotice-Downloader-Multisite' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: downloaderDefinition
    parameters: {
      storageAccountName: {
        value: storageAccountName
      }
    }
  }
}

// ============================================================================
// Scanner (references Downloader callback URL)
// ============================================================================
resource scannerLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${logicAppName}-scanner'
  location: location
  tags: union(tags, { Workflow: 'CriticalNotice-Scanner-Multisite' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: scannerDefinition
    parameters: {
      storageAccountName: {
        value: storageAccountName
      }
      downloaderCallbackUrl: {
        value: listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', downloaderLogicApp.name, 'HTTP_Request'), '2019-05-01').value
      }
    }
  }
  dependsOn: []
}

// ============================================================================
// Parser (processes raw HTML → structured JSON via Foundry)
// ============================================================================
resource parserLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${logicAppName}-parser'
  location: location
  tags: union(tags, { Workflow: 'CriticalNotice-Parser-Multisite' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: parserDefinition
    parameters: {
      storageAccountName: {
        value: storageAccountName
      }
      foundryEndpoint: {
        value: foundryEndpoint
      }
      foundryApiKey: {
        value: foundryApiKey
      }
      foundryDeploymentName: {
        value: foundryDeploymentName
      }
    }
  }
  dependsOn: []
}

// ============================================================================
// Outputs
// ============================================================================

@description('Scanner Logic App resource ID')
output scannerLogicAppId string = scannerLogicApp.id

@description('Scanner Logic App name')
output scannerLogicAppName string = scannerLogicApp.name

@description('Scanner Logic App managed identity principal ID')
output logicAppPrincipalId string = scannerLogicApp.identity.principalId

@description('Downloader Logic App resource ID')
output downloaderLogicAppId string = downloaderLogicApp.id

@description('Downloader Logic App name')
output downloaderLogicAppName string = downloaderLogicApp.name

@description('Downloader Logic App managed identity principal ID')
output downloaderPrincipalId string = downloaderLogicApp.identity.principalId

@description('Downloader HTTP trigger callback URL')
#disable-next-line outputs-should-not-contain-secrets
output downloaderCallbackUrl string = listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', downloaderLogicApp.name, 'HTTP_Request'), '2019-05-01').value

// Legacy output for backward compatibility
@description('Primary Logic App name (Scanner)')
output logicAppName string = scannerLogicApp.name

@description('Primary Logic App ID (Scanner)')
output logicAppId string = scannerLogicApp.id

@description('Parser Logic App resource ID')
output parserLogicAppId string = parserLogicApp.id

@description('Parser Logic App name')
output parserLogicAppName string = parserLogicApp.name

@description('Parser Logic App managed identity principal ID')
output parserPrincipalId string = parserLogicApp.identity.principalId
