// Azure SQL (serverless) for parsed-notice landing.
// POC: public endpoint with "Allow Azure services"; private endpoint deferred.
// AAD-only auth. DDL + ADF MI grant performed via deploymentScripts.

@description('Azure region')
param location string

@description('SQL logical server name (must be globally unique)')
param sqlServerName string

@description('SQL database name')
param sqlDatabaseName string = 'noticesdb'

@description('AAD object ID granted as SQL AAD admin (a user, group, or SP)')
param sqlAdminAadObjectId string

@description('AAD login name shown in the portal for the SQL AAD admin')
param sqlAdminAadLoginName string

@description('Resource tags')
param tags object = {}

// ----------------------------------------------------------------------------
// SQL server + serverless DB
// ----------------------------------------------------------------------------

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'User'
      login: sqlAdminAadLoginName
      sid: sqlAdminAadObjectId
      tenantId: subscription().tenantId
    }
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: '1.2'
  }
}

resource aadOnly 'Microsoft.Sql/servers/azureADOnlyAuthentications@2023-08-01-preview' = {
  parent: sqlServer
  name: 'Default'
  properties: {
    azureADOnlyAuthentication: true
  }
}

resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 1073741824
    autoPauseDelay: 60
    minCapacity: json('0.5')
    zoneRedundant: false
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: 'Local'
  }
}

// DDL + ADF MI grants are performed post-deploy by the AAD admin via sqlcmd
// against infra/sql/notices.sql and infra/sql/grants.sql. We keep this out of
// Bicep deployment scripts to avoid the chicken-and-egg of authenticating a
// script identity into an AAD-only SQL server. See README "Post-deploy" section.

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------

@description('SQL server resource ID')
output sqlServerId string = sqlServer.id

@description('SQL server name')
output sqlServerName string = sqlServer.name

@description('SQL server fully qualified domain name')
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName

@description('SQL database name')
output sqlDatabaseName string = sqlDb.name
