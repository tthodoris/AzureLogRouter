targetScope = 'resourceGroup'

@description('Existing dedicated test workspace.')
param workspaceName string
param location string
param ingestionPrincipalId string
param dcrName string = 'dcr-synthetic-signins'

var columns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'AADTenantId', type: 'string' }
  { name: 'UserPrincipalName', type: 'string' }
  { name: 'Message', type: 'string' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: 'SyntheticSigninLogs_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: 30
    totalRetentionInDays: 30
    schema: {
      name: 'SyntheticSigninLogs_CL'
      columns: columns
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Direct'
  properties: {
    streamDeclarations: {
      'Custom-SyntheticSigninLogs_CL': { columns: columns }
    }
    destinations: {
      logAnalytics: [
        { name: 'testWorkspace', workspaceResourceId: workspace.id }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-SyntheticSigninLogs_CL']
        destinations: ['testWorkspace']
        outputStream: 'Custom-SyntheticSigninLogs_CL'
        transformKql: 'source'
      }
    ]
  }
  dependsOn: [table]
}

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, ingestionPrincipalId, 'synthetic-signin-publisher')
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: ingestionPrincipalId
    principalType: 'User'
  }
}

output dcrResourceId string = dcr.id
output dcrImmutableId string = dcr.properties.immutableId!
output ingestionEndpoint string = dcr.properties.endpoints!.logsIngestion!
