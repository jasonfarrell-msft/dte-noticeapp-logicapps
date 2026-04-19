// Azure Virtual Network for Logic Apps Standard VNet Integration
// Provides network isolation for critical notice processing infrastructure

@description('Location for resources')
param location string

@description('VNet name')
param vnetName string = 'vnet-dte-noticeapp-eus2-mx01'

@description('Tags to apply to resources')
param tags object = {}

// ============================================================================
// Virtual Network
// ============================================================================
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-logicapps'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'delegation-webserverfarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [ location ]
            }
            {
              service: 'Microsoft.KeyVault'
              locations: [ location ]
            }
          ]
          networkSecurityGroup: {
            id: nsgLogicApps.id
          }
        }
      }
      {
        name: 'snet-privateendpoints'
        properties: {
          addressPrefix: '10.0.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ============================================================================
// Network Security Group for Logic Apps Subnet
// ============================================================================
resource nsgLogicApps 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: 'nsg-logicapps-${location}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '*'
          description: 'Allow outbound to Azure services'
        }
      }
      {
        name: 'AllowInternetOutbound'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'Allow outbound to internet (for external APIs like Enbridge)'
        }
      }
      {
        name: 'AllowLogicAppsInfraInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'LogicAppsManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
          description: 'Allow Logic Apps management traffic'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow Azure Load Balancer probes'
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('VNet resource ID')
output vnetId string = vnet.id

@description('VNet name')
output vnetName string = vnet.name

@description('Logic Apps subnet resource ID')
output logicAppsSubnetId string = vnet.properties.subnets[0].id

@description('Private Endpoints subnet resource ID')
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id

@description('Logic Apps subnet name')
output logicAppsSubnetName string = 'snet-logicapps'

@description('Private Endpoints subnet name')
output privateEndpointsSubnetName string = 'snet-privateendpoints'
