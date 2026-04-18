// Azure Data Factory for data movement to Fabric
// Handles transformation and push to Fabric Lakehouse
// Includes mock pipelines for Fabric integration

@description('Location for the Data Factory')
param location string

@description('Name of the Data Factory')
param dataFactoryName string

@description('Tags to apply to resources')
param tags object = {}

@description('Storage account resource ID for linked service (unused, kept for backward compat)')
#disable-next-line no-unused-params
param storageAccountId string = ''

@description('Storage account name for connection')
param storageAccountName string = 'stdtenoticeappeus2mx01'

// Data Factory resource
resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: dataFactoryName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

// ============================================================================
// Linked Services
// ============================================================================

// Linked Service: Azure Blob Storage (using managed identity)
// Linked Service: Azure Blob Storage (using managed identity)
resource blobLinkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: dataFactory
  name: 'AzureBlobStorage_ManagedIdentity'
  properties: {
    type: 'AzureBlobStorage'
    typeProperties: {
      // Using blob endpoint URL - required format for ADF linked service
      #disable-next-line no-hardcoded-env-urls
      serviceEndpoint: 'https://${storageAccountName}.blob.core.windows.net'
      accountKind: 'StorageV2'
    }
    connectVia: {
      referenceName: 'AutoResolveIntegrationRuntime'
      type: 'IntegrationRuntimeReference'
    }
    description: 'Linked service to critical notices blob storage using managed identity'
  }
  dependsOn: [
    integrationRuntime
  ]
}

// Linked Service: Microsoft Fabric Lakehouse (mock - placeholder endpoint)
resource fabricLinkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: dataFactory
  name: 'FabricLakehouse_Mock'
  properties: {
    type: 'AzureBlobFS'
    typeProperties: {
      url: 'https://onelake.dfs.fabric.microsoft.com'
      accountKey: {
        type: 'SecureString'
        value: 'PLACEHOLDER_FABRIC_KEY_CONFIGURE_AFTER_DEPLOYMENT'
      }
    }
    description: 'Mock linked service to Fabric Lakehouse - configure after deployment with actual workspace credentials'
  }
}

// Integration Runtime (Auto-resolve)
resource integrationRuntime 'Microsoft.DataFactory/factories/integrationRuntimes@2018-06-01' = {
  parent: dataFactory
  name: 'AutoResolveIntegrationRuntime'
  properties: {
    type: 'Managed'
    typeProperties: {
      computeProperties: {
        location: 'AutoResolve'
      }
    }
  }
}

// ============================================================================
// Datasets
// ============================================================================

// Dataset: Source - Raw HTML files in Blob Storage
resource blobHtmlDataset 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: dataFactory
  name: 'BlobHtmlSource'
  properties: {
    type: 'Binary'
    linkedServiceName: {
      referenceName: blobLinkedService.name
      type: 'LinkedServiceReference'
    }
    typeProperties: {
      location: {
        type: 'AzureBlobStorageLocation'
        container: 'critical-notices'
        folderPath: 'raw-html'
      }
    }
    description: 'Raw HTML files from critical notice downloads'
    folder: {
      name: 'Sources'
    }
  }
}

// Dataset: Source - Parsed notices (JSON/Parquet)
resource parsedNoticesDataset 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: dataFactory
  name: 'ParsedNoticesSource'
  properties: {
    type: 'Parquet'
    linkedServiceName: {
      referenceName: blobLinkedService.name
      type: 'LinkedServiceReference'
    }
    typeProperties: {
      location: {
        type: 'AzureBlobStorageLocation'
        container: 'critical-notices'
        folderPath: 'parsed'
        fileName: '*.parquet'
      }
      compressionCodec: 'snappy'
    }
    description: 'Parsed notice data in Parquet format'
    folder: {
      name: 'Sources'
    }
    schema: [
      { name: 'notice_id', type: 'String' }
      { name: 'business_unit', type: 'String' }
      { name: 'notice_type', type: 'String' }
      { name: 'posted_datetime', type: 'DateTime' }
      { name: 'effective_datetime', type: 'DateTime' }
      { name: 'end_datetime', type: 'DateTime' }
      { name: 'subject', type: 'String' }
      { name: 'html_blob_path', type: 'String' }
      { name: 'extracted_at', type: 'DateTime' }
    ]
  }
}

// Dataset: Sink - Fabric Lakehouse table (mock)
resource fabricSinkDataset 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: dataFactory
  name: 'FabricLakehouseSink'
  properties: {
    type: 'Parquet'
    linkedServiceName: {
      referenceName: fabricLinkedService.name
      type: 'LinkedServiceReference'
    }
    typeProperties: {
      location: {
        type: 'AzureBlobFSLocation'
        fileSystem: 'CriticalNotices_Lakehouse'
        folderPath: 'Tables/raw_notices'
      }
      compressionCodec: 'snappy'
    }
    description: 'Mock sink to Fabric Lakehouse raw_notices table'
    folder: {
      name: 'Sinks'
    }
  }
}

// ============================================================================
// Pipelines
// ============================================================================

// Pipeline: Ingest to Fabric (copies parsed notices to Fabric Lakehouse)
resource ingestToFabricPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: dataFactory
  name: 'IngestToFabric'
  properties: {
    description: 'Copies parsed critical notices from Blob Storage to Fabric Lakehouse. NOTE: Fabric linked service must be configured with actual credentials before this pipeline will work.'
    activities: [
      {
        name: 'CopyToFabricLakehouse'
        type: 'Copy'
        typeProperties: {
          source: {
            type: 'ParquetSource'
            storeSettings: {
              type: 'AzureBlobStorageReadSettings'
              recursive: true
              wildcardFolderPath: '*'
              wildcardFileName: '*.parquet'
              enablePartitionDiscovery: false
            }
          }
          sink: {
            type: 'ParquetSink'
            storeSettings: {
              type: 'AzureBlobFSWriteSettings'
            }
          }
          enableStaging: false
        }
        inputs: [
          {
            referenceName: parsedNoticesDataset.name
            type: 'DatasetReference'
          }
        ]
        outputs: [
          {
            referenceName: fabricSinkDataset.name
            type: 'DatasetReference'
          }
        ]
        policy: {
          retry: 3
          retryIntervalInSeconds: 30
          timeout: '00:30:00'
        }
      }
    ]
    annotations: [
      'CriticalNotices'
      'FabricIngestion'
      'MockPipeline'
    ]
    folder: {
      name: 'Ingestion'
    }
  }
}

// Pipeline: Archive old HTML files
resource archiveHtmlPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: dataFactory
  name: 'ArchiveRawHtml'
  properties: {
    description: 'Archives raw HTML files older than 30 days by moving to archive container. Runs on schedule.'
    activities: [
      {
        name: 'GetFilesToArchive'
        type: 'GetMetadata'
        typeProperties: {
          dataset: {
            referenceName: blobHtmlDataset.name
            type: 'DatasetReference'
          }
          fieldList: [
            'childItems'
          ]
          storeSettings: {
            type: 'AzureBlobStorageReadSettings'
            recursive: true
          }
        }
      }
    ]
    annotations: [
      'CriticalNotices'
      'Maintenance'
    ]
    folder: {
      name: 'Maintenance'
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Data Factory resource ID')
output dataFactoryId string = dataFactory.id

@description('Data Factory name')
output dataFactoryName string = dataFactory.name

@description('Data Factory managed identity principal ID')
output dataFactoryPrincipalId string = dataFactory.identity.principalId

@description('Blob Storage Linked Service name')
output blobLinkedServiceName string = blobLinkedService.name

@description('Fabric Linked Service name (mock)')
output fabricLinkedServiceName string = fabricLinkedService.name

@description('Ingest pipeline name')
output ingestPipelineName string = ingestToFabricPipeline.name
