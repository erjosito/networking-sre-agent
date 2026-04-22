// SRE Agent for Azure Networking
// Deploys: User-assigned managed identity, Application Insights,
//          SRE Agent (Microsoft.App/agents), and RBAC role assignments.
//
// NOTE: Knowledge base files (from knowledge/ directory) must be uploaded
//       via the SRE Agent portal after deployment — Bicep cannot upload them.
//       Azure Monitor is the default incident platform and is auto-connected.

@description('Azure region — must be eastus2, swedencentral, or australiaeast')
param location string

@description('Resource naming prefix')
param prefix string

@description('Access level for the agent: High (Reader+Contributor) or Low (Reader only)')
@allowed(['High', 'Low'])
param accessLevel string = 'High'

@description('Agent mode: Review (propose+approve), Autonomous, or ReadOnly')
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param agentMode string = 'Review'

@description('Microsoft Entra group ID for initial sponsor group (required for agent identity). Members of this group can manage the agent.')
param initialSponsorGroupId string

@description('Resource group IDs the agent should monitor (full resource IDs)')
param managedResourceGroupIds array = []

@description('Log Analytics workspace ID for the agent App Insights')
param logAnalyticsWorkspaceId string

@description('Upgrade channel for the agent')
@allowed(['Stable', 'Preview'])
param upgradeChannel string = 'Stable'

// ──────────────────────────────────────────────
// User-Assigned Managed Identity
// ──────────────────────────────────────────────
resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-sre-agent-identity'
  location: location
}

// ──────────────────────────────────────────────
// Application Insights for the SRE Agent
// ──────────────────────────────────────────────
resource agentAppInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-sre-agent-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    RetentionInDays: 30
  }
}

// ──────────────────────────────────────────────
// SRE Agent (Microsoft.App/agents)
// API: 2026-01-01 (GA)
// Docs: https://learn.microsoft.com/azure/sre-agent/overview
// ──────────────────────────────────────────────
resource sreAgent 'Microsoft.App/agents@2026-01-01' = {
  name: '${prefix}-sre-agent'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${agentIdentity.id}': {}
    }
  }
  tags: {
    purpose: 'Azure Networking SRE'
    managedBy: 'bicep'
  }
  properties: {
    actionConfiguration: {
      accessLevel: accessLevel
      identity: agentIdentity.id
      mode: agentMode
    }
    agentIdentity: {
      initialSponsorGroupId: initialSponsorGroupId
    }
    knowledgeGraphConfiguration: {
      identity: agentIdentity.id
      managedResources: managedResourceGroupIds
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: agentAppInsights.properties.AppId
        connectionString: agentAppInsights.properties.ConnectionString
      }
    }
    defaultModel: {
      name: 'gpt-5'
      provider: 'MicrosoftFoundry'
    }
    upgradeChannel: upgradeChannel
  }
}

// ──────────────────────────────────────────────
// RBAC Role Assignments on the resource group
// ──────────────────────────────────────────────
// Built-in role definition IDs
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

// Reader — always assigned
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentIdentity.id, readerRoleId)
  properties: {
    principalId: agentIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Log Analytics Reader — always assigned
resource logAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentIdentity.id, logAnalyticsReaderRoleId)
  properties: {
    principalId: agentIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Reader — always assigned
resource monitoringReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentIdentity.id, monitoringReaderRoleId)
  properties: {
    principalId: agentIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Contributor — assigned when accessLevel is High
resource contributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (accessLevel == 'High') {
  name: guid(resourceGroup().id, agentIdentity.id, contributorRoleId)
  properties: {
    principalId: agentIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Network Contributor — for networking-specific agent operations
resource networkContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentIdentity.id, networkContributorRoleId)
  properties: {
    principalId: agentIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ──────────────────────────────────────────────
// Subscription-scoped: Monitoring Contributor
// (needed for the agent to acknowledge/close Azure Monitor alerts)
// This is deployed as a separate module from main.bicep at subscription scope
// ──────────────────────────────────────────────

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output agentId string = sreAgent.id
output agentName string = sreAgent.name
output managedIdentityId string = agentIdentity.id
output managedIdentityPrincipalId string = agentIdentity.properties.principalId
output managedIdentityClientId string = agentIdentity.properties.clientId
output appInsightsConnectionString string = agentAppInsights.properties.ConnectionString
output agentPortalUrl string = 'https://sre.azure.com/agent/${sreAgent.id}'
