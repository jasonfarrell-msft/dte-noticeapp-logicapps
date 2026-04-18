// Microsoft Foundry (Azure AI Services / Cognitive Services v2) for AI-powered notice parsing
// Deploys: Azure AI Services account with GPT-5.2 deployment
// Uses: Azure AI Services (AIServices) kind for v2 APIs

@description('Location for resources')
param location string

@description('Name for the Cognitive Services account')
param foundryAccountName string = 'cog-dte-noticeapp-eus2-mx01'

@description('Tags to apply to resources')
param tags object = {}

@description('SKU for Cognitive Services account')
@allowed(['S0', 'S1'])
param sku string = 'S0'

@description('GPT model deployment name')
param deploymentName string = 'gpt-5.2'

@description('GPT model version')
param modelVersion string = '2025-12-11'

@description('Deployment capacity (TPM in thousands)')
param deploymentCapacity int = 1

// ============================================================================
// Cognitive Services Account
// ============================================================================
resource cognitiveServicesAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: foundryAccountName
  location: location
  tags: union(tags, { Service: 'Foundry-AI-Extraction' })
  kind: 'AIServices'
  sku: {
    name: sku
  }
  properties: {
    customSubDomainName: foundryAccountName
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
    disableLocalAuth: false
  }
}

// ============================================================================
// GPT-5.2 Deployment
// ============================================================================
resource gptDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: cognitiveServicesAccount
  name: deploymentName
  sku: {
    // DataZoneStandard often has separate quota from GlobalStandard
    name: 'DataZoneStandard'
    capacity: deploymentCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.2'
      version: modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.Default'
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Cognitive Services account name')
output foundryAccountName string = cognitiveServicesAccount.name

@description('Foundry endpoint URL')
output foundryEndpoint string = cognitiveServicesAccount.properties.endpoint

@description('Foundry resource ID')
output foundryResourceId string = cognitiveServicesAccount.id

@description('GPT deployment name')
output deploymentName string = gptDeployment.name

@description('Foundry API key (primary)')
#disable-next-line outputs-should-not-contain-secrets
output foundryApiKey string = cognitiveServicesAccount.listKeys().key1
