targetScope = 'resourceGroup'

@description('Must match the existing central workspace region.')
param location string

@minLength(3)
@maxLength(30)
param namePrefix string

param eventHubName string = 'central-logs'
param consumerGroup string = 'log-router'

@description('Reuse this existing dedicated namespace in the router resource group instead of creating one.')
param existingEventHubNamespaceName string = ''

@minValue(1)
@maxValue(40)
param throughputUnits int = 12

@minValue(1)
@maxValue(32)
param partitionCount int = 32

@minValue(1)
@maxValue(7)
param retentionDays int = 7

@description('Keep disabled until target DCRs, configuration, and application package are ready.')
param routerEnabled bool = false

var suffix = uniqueString(resourceGroup().id, namePrefix)
var namespaceName = empty(existingEventHubNamespaceName) ? 'ehlr-${suffix}' : existingEventHubNamespaceName
var blobOwnerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var hubReceiverRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde')

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-identity'
  location: location
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stlr${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'deployments'
  properties: { publicAccess: 'None' }
}

resource quarantineContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'quarantine'
  properties: { publicAccess: 'None' }
}

resource blobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, blobOwnerRole)
  scope: storage
  properties: {
    roleDefinitionId: blobOwnerRole
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource createdEventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = if (empty(existingEventHubNamespaceName)) {
  name: namespaceName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: throughputUnits
  }
  properties: {
    isAutoInflateEnabled: true
    maximumThroughputUnits: 40
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    // Azure Monitor workspace export uses shared-access authorization; the router uses managed identity.
    disableLocalAuth: false
  }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: namespaceName
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: eventHubName
  properties: {
    partitionCount: partitionCount
    messageRetentionInDays: retentionDays
  }
  dependsOn: [createdEventHubNamespace]
}

resource consumer 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: eventHub
  name: consumerGroup
}

resource hubAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHub.id, identity.id, hubReceiverRole)
  scope: eventHub
  properties: {
    roleDefinitionId: hubReceiverRole
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-plan'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: 'func-lr-${suffix}'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: { minTlsVersion: '1.2' }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 100
      }
    }
  }
  dependsOn: [blobAccess, hubAccess]
}

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: identity.properties.clientId
    AZURE_CLIENT_ID: identity.properties.clientId
    ExportHub__fullyQualifiedNamespace: '${eventHubNamespace.name}.servicebus.windows.net'
    ExportHub__credential: 'managedidentity'
    ExportHub__clientId: identity.properties.clientId
    ExportHubName: eventHub.name
    ExportConsumerGroup: consumer.name
    FailureStorageUri: '${storage.properties.primaryEndpoints.blob}${quarantineContainer.name}'
    RoutingConfigPath: 'routing.json'
    'AzureWebJobs.RouteCentralLogs.Disabled': string(!routerEnabled)
  }
}

output functionAppName string = functionApp.name
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
output storageAccountName string = storage.name
output eventHubNamespaceResourceId string = eventHubNamespace.id
output eventHubNamespaceHost string = '${eventHubNamespace.name}.servicebus.windows.net'
