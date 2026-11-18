targetScope = 'resourceGroup'

@description('Existing central workspace in this resource group.')
param workspaceName string
param eventHubNamespaceResourceId string
param eventHubName string
param tables string[]
param enabled bool = true
param exportRuleName string = 'central-spoke-router'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource exportRule 'Microsoft.OperationalInsights/workspaces/dataExports@2023-09-01' = {
  parent: workspace
  name: exportRuleName
  properties: {
    enable: enabled
    tableNames: tables
    destination: {
      resourceId: eventHubNamespaceResourceId
      metaData: { eventHubName: eventHubName }
    }
  }
}
