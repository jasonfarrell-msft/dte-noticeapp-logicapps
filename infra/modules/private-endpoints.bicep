// Private Endpoints and DNS Zones for VNet-isolated architecture
// Secures access to Storage, Foundry (Cognitive Services), and Key Vault

@description('Location for resources')
param location string

@description('Tags to apply to resources')
param tags object = {}

@description('VNet resource ID')
param vnetId string

@description('Private Endpoints subnet resource ID')
param privateEndpointsSubnetId string

@description('Storage Account resource ID')
param storageAccountId string

@description('Storage Account name (for private endpoint naming)')
param storageAccountName string

@description('Foundry (Cognitive Services) resource ID')
param foundryResourceId string

@description('Foundry account name (for private endpoint naming)')
param foundryAccountName string

@description('Key Vault resource ID')
param keyVaultId string

@description('Key Vault name (for private endpoint naming)')
param keyVaultName string

// ============================================================================
// Private DNS Zones
// ============================================================================

resource privateDnsZoneBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
  tags: tags
}

resource privateDnsZoneCognitiveServices 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.cognitiveservices.azure.com'
  location: 'global'
  tags: tags
}

resource privateDnsZoneKeyVault 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

// ============================================================================
// DNS Zone VNet Links
// ============================================================================

resource vnetLinkBlob 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneBlob
  name: 'link-blob-vnet'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource vnetLinkCognitiveServices 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneCognitiveServices
  name: 'link-cognitiveservices-vnet'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource vnetLinkKeyVault 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneKeyVault
  name: 'link-keyvault-vnet'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// ============================================================================
// Private Endpoints
// ============================================================================

// Storage Account - Blob
resource peStorageBlob 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-storage-blob'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// Storage Account - Blob DNS Registration
resource peStorageBlobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peStorageBlob
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZoneBlob.id
        }
      }
    ]
  }
}

// Foundry (Cognitive Services)
resource peFoundry 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-${foundryAccountName}-account'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-foundry-account'
        properties: {
          privateLinkServiceId: foundryResourceId
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

// Foundry DNS Registration
resource peFoundryDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peFoundry
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-cognitiveservices-azure-com'
        properties: {
          privateDnsZoneId: privateDnsZoneCognitiveServices.id
        }
      }
    ]
  }
}

// Key Vault
resource peKeyVault 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-${keyVaultName}-vault'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-keyvault-vault'
        properties: {
          privateLinkServiceId: keyVaultId
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

// Key Vault DNS Registration
resource peKeyVaultDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peKeyVault
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: privateDnsZoneKeyVault.id
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Storage blob private endpoint ID')
output storageBlobPrivateEndpointId string = peStorageBlob.id

@description('Foundry private endpoint ID')
output foundryPrivateEndpointId string = peFoundry.id

@description('Key Vault private endpoint ID')
output keyVaultPrivateEndpointId string = peKeyVault.id

@description('Blob private DNS zone ID')
output blobDnsZoneId string = privateDnsZoneBlob.id

@description('Cognitive Services private DNS zone ID')
output cognitiveServicesDnsZoneId string = privateDnsZoneCognitiveServices.id

@description('Key Vault private DNS zone ID')
output keyVaultDnsZoneId string = privateDnsZoneKeyVault.id
