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

param existingVnetId string = ''
param existingFunctionSubnetId string = ''
param existingPrivateEndpointSubnetId string = ''
param vnetCidr string = '10.250.0.0/24'
param functionSubnetCidr string = '10.250.0.0/27'
param privateEndpointSubnetCidr string = '10.250.0.32/28'

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
    publicNetworkAccess: 'Disabled'
    // Azure Monitor workspace export uses shared-access authorization; the router uses managed identity.
    disableLocalAuth: false
  }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: namespaceName
}

resource namespaceFirewall 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = {
  parent: eventHubNamespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Disabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
    ipRules: []
    virtualNetworkRules: []
  }
  dependsOn: [createdEventHubNamespace]
}

var createNetwork = empty(existingVnetId)
var routerVnetResourceId = createNetwork ? routerNetwork!.id : existingVnetId
var functionSubnetId = createNetwork ? functionsSubnet!.id : existingFunctionSubnetId
var endpointSubnetId = createNetwork ? endpointSubnet!.id : existingPrivateEndpointSubnetId

resource egressIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (createNetwork) {
  name: 'pip-lr-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource egress 'Microsoft.Network/natGateways@2024-05-01' = if (createNetwork) {
  name: 'nat-lr-${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIpAddresses: [{ id: egressIp!.id }] }
}

resource routerNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = if (createNetwork) {
  name: 'vnet-lr-${suffix}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetCidr] }
  }
}

resource functionsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (createNetwork) {
  parent: routerNetwork
  name: 'functions'
  properties: {
    addressPrefix: functionSubnetCidr
    defaultOutboundAccess: false
    natGateway: { id: egress!.id }
    serviceEndpoints: [{ service: 'Microsoft.Storage' }]
    delegations: [
      {
        name: 'flex-consumption'
        properties: { serviceName: 'Microsoft.App/environments' }
      }
    ]
  }
}

resource endpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (createNetwork) {
  parent: routerNetwork
  name: 'private-endpoints'
  properties: {
    addressPrefix: privateEndpointSubnetCidr
    privateEndpointNetworkPolicies: 'Disabled'
  }
  dependsOn: [functionsSubnet]
}

var privateZoneNames = ['privatelink.servicebus.windows.net', 'privatelink.azurewebsites.net']

resource privateDns 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in privateZoneNames: {
  name: zoneName
  location: 'global'
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, i) in privateZoneNames: {
  parent: privateDns[i]
  name: 'router-${suffix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: routerVnetResourceId }
  }
}]

resource hubEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-eventhubs-${suffix}'
  location: location
  properties: {
    subnet: { id: endpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'eventhubs'
        properties: {
          privateLinkServiceId: eventHubNamespace.id
          groupIds: ['namespace']
        }
      }
    ]
  }
  dependsOn: [namespaceFirewall]
}

resource hubDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: hubEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'eventhubs'
        properties: { privateDnsZoneId: privateDns[0].id }
      }
    ]
  }
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
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: functionSubnetId
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
  dependsOn: [blobAccess, hubAccess, hubDnsGroup, dnsLinks[0]]
}

resource functionEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-function-${suffix}'
  location: location
  properties: {
    subnet: { id: endpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'function'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource functionDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: functionEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'function'
        properties: { privateDnsZoneId: privateDns[1].id }
      }
    ]
  }
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
output routerVnetId string = routerVnetResourceId
output functionScmHost string = first(filter(functionApp.properties.enabledHostNames!, host => contains(host, '.scm.')))
