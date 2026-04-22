// Subscription-scoped role assignment for SRE Agent
// Assigns Monitoring Contributor at subscription level so the agent
// can acknowledge and close Azure Monitor alerts.

targetScope = 'subscription'

@description('Principal ID of the SRE Agent managed identity')
param principalId string

// Monitoring Contributor role definition ID
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'

resource monitoringContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, monitoringContributorRoleId)
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}
