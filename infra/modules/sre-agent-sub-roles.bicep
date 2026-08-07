// Subscription-scoped role assignments for SRE Agent
// - Monitoring Contributor: acknowledge/close Azure Monitor alerts.
// - Network Contributor: read and QUERY Network Watcher Connection Monitors, which
//   Azure places in the auto-managed NetworkWatcherRG (not the lab RG). Without this,
//   the agent's `az network watcher connection-monitor query` fails AuthorizationFailed
//   on Microsoft.Network/networkWatchers/connectionMonitors/query/action and stalls on
//   an interactive permission grant. Subscription scope is used because NetworkWatcherRG
//   is created by Azure on demand and may not exist at RG-scoped deploy time.

targetScope = 'subscription'

@description('Principal ID of the SRE Agent managed identity')
param principalId string

// Monitoring Contributor role definition ID
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
// Network Contributor role definition ID
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

resource monitoringContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, monitoringContributorRoleId)
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource networkContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, networkContributorRoleId)
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}
