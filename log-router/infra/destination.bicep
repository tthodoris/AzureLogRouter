targetScope = 'resourceGroup'

@description('Existing spoke workspace in this resource group.')
param workspaceName string
param workspaceLocation string
param dcrName string = 'dcr-central-router'
param routerPrincipalId string
param sourceWorkspaceResourceId string
param tablePolicies {
  sourceTable: string
  targetTable: string
  createTable: bool
  columns: { name: string, type: string }[]
  projection: string
  originSubscriptionIds: string[]
  originTenantIds: string[]
}[]

var columns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'OriginSubscriptionId', type: 'string' }
  { name: 'OriginTenantId', type: 'string' }
  { name: 'OriginResourceId', type: 'string' }
  { name: 'SourceTable', type: 'string' }
  { name: 'SourceWorkspaceResourceId', type: 'string' }
  { name: 'DeliveryId', type: 'string' }
  { name: 'Payload', type: 'dynamic' }
]
var emptyOrigin = ['']

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource tables 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for policy in tablePolicies: if (policy.createTable) {
  parent: workspace
  name: policy.targetTable
  properties: {
    plan: 'Analytics'
    schema: {
      name: policy.targetTable
      columns: policy.columns
    }
  }
}]

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: workspaceLocation
  kind: 'Direct'
  properties: {
    streamDeclarations: toObject(tablePolicies, p => 'Custom-${p.targetTable}', p => { columns: columns })
    destinations: {
      logAnalytics: [
        { name: 'spoke', workspaceResourceId: workspace.id }
      ]
    }
    dataFlows: [for policy in tablePolicies: {
      streams: ['Custom-${policy.targetTable}']
      destinations: ['spoke']
      outputStream: 'Custom-${policy.targetTable}'
      transformKql: 'source | where SourceWorkspaceResourceId =~ \'${sourceWorkspaceResourceId}\' and SourceTable == \'${policy.sourceTable}\' and ((OriginSubscriptionId in~ (${join(map(concat(policy.originSubscriptionIds, emptyOrigin), id => '\'${id}\''), ',')}) and isnotempty(OriginSubscriptionId) and isempty(OriginTenantId)) or (OriginTenantId in~ (${join(map(concat(policy.originTenantIds, emptyOrigin), id => '\'${id}\''), ',')}) and isnotempty(OriginTenantId) and isempty(OriginSubscriptionId))) | project ${policy.projection}'
    }]
  }
  dependsOn: [tables]
}

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, routerPrincipalId, 'metrics-publisher')
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: routerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output dcrResourceId string = dcr.id
output dcrImmutableId string = dcr.properties.immutableId!
output ingestionEndpoint string = dcr.properties.endpoints!.logsIngestion!
