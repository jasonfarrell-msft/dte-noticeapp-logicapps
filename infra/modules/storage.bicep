// Storage Account with blob containers and lifecycle policy
// For multi-site critical notice ingestion pipeline (Enbridge + TCeConnects)

@description('Location for the storage account')
param location string

@description('Name of the storage account')
param storageAccountName string

@description('Tags to apply to resources')
param tags object = {}

// Storage Account - Hot tier for frequent polling access
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Blob Services
resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// Container: critical-notices (unified for all sources)
// Structure:
//   notices/{source}/{pipeline}/{noticeId}.json     - Canonical notice metadata
//   raw/{source}/{date}/{pipeline}/{noticeId}.html  - Raw HTML content
//   tracking/{source}/{pipeline}.json               - Last-seen tracking per unit
//   indices/daily/{date}/*.json                     - Daily index for reporting
resource criticalNoticesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobServices
  name: 'critical-notices'
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle Management Policy
// - Move to Cool tier after 30 days
// - Move to Archive tier after 90 days
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'MoveToCoolAfter30Days'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'critical-notices/'
              ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 90
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Outputs
@description('Storage account resource ID')
output storageAccountId string = storageAccount.id

@description('Storage account name')
output storageAccountName string = storageAccount.name

@description('Storage account blob endpoint')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
