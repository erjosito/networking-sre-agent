targetScope = 'subscription'

@description('Principal ID of the Observability Agent managed identity')
param principalId string

@description('Resource naming prefix')
param prefix string

var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'

resource subscriptionMonitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, monitoringContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output deploymentName string = '${prefix}-observability-sub-roles'
