@description('Azure region for the workload VM and Application Insights')
param location string

@description('Supported autonomous-operations region for the Observability Agent and Azure Monitor workspace')
param observabilityLocation string

@description('Resource naming prefix')
param prefix string

@description('Existing spoke subnet resource ID for the API VM')
param subnetId string

@description('Existing Log Analytics workspace resource ID linked to Application Insights')
param logAnalyticsWorkspaceId string

@description('Private Endpoint static website FQDN')
param privateEndpointFqdn string

@description('Also perform an HTTPS content check against the Private Endpoint. Keep false when storage policy prevents publishing a test page.')
param enablePrivateEndpointHttpCheck bool = false

@description('Cross-hub HTTP dependency URL')
param crossHubUrl string

@description('Optional on-prem HTTP dependency URL')
param onpremUrl string = ''

@description('Dependency check delayed by the opt-in dependency-latency profile')
@allowed([
  'private_endpoint_dns'
  'private_endpoint_http'
  'cross_hub_http'
  'onprem_http'
])
param dependencyLatencyTarget string = 'cross_hub_http'

@minValue(1)
@maxValue(30000)
@description('Delay injected by the dependency-latency profile')
param dependencyLatencyMs int = 3000

@minValue(1)
@maxValue(30000)
@description('Dependency duration that fires the latency alert')
param dependencyLatencyAlertThresholdMs int = 2000

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password for serial console access')
param adminPassword string

@description('SSH public key')
param adminPublicKey string

@description('Email address for application alert notifications')
param alertEmail string = 'netops@example.com'

var vmName = '${prefix}-observability-api'
var apiRoleName = '${prefix}-network-transaction-api'
var appInsightsName = '${prefix}-observability-api-ai'
var monitorWorkspaceName = '${prefix}-observability-amw'
var observabilityAgentName = '${prefix}-observability-agent'
var useSSHKey = !empty(adminPublicKey)
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
var envContent = join([
  'APPLICATIONINSIGHTS_CONNECTION_STRING=${appInsights.properties.ConnectionString}'
  'OTEL_SERVICE_NAME=${apiRoleName}'
  'PRIVATE_ENDPOINT_FQDN=${privateEndpointFqdn}'
  'PRIVATE_ENDPOINT_URL=${enablePrivateEndpointHttpCheck ? 'https://${privateEndpointFqdn}/' : ''}'
  'CROSS_HUB_URL=${crossHubUrl}'
  'ONPREM_URL=${onpremUrl}'
  'PRIVATE_ADDRESS_PREFIX=10.'
  'DEPENDENCY_TIMEOUT_SECONDS=5'
  'LAB_DEPENDENCY_LATENCY_TARGET=${dependencyLatencyTarget}'
  'LAB_DEPENDENCY_LATENCY_MS=${dependencyLatencyMs}'
  'PORT=8080'
  ''
], '\n')
var cloudInitTemplate = loadTextContent('../cloud-init/observability-api.yaml')
var cloudInitWithApp = replace(cloudInitTemplate, 'APP_PY_BASE64_PLACEHOLDER', loadFileAsBase64('../observability-api/app.py'))
var cloudInitWithRequirements = replace(cloudInitWithApp, 'REQUIREMENTS_BASE64_PLACEHOLDER', loadFileAsBase64('../observability-api/requirements.txt'))
var workloadCloudInit = base64(replace(cloudInitWithRequirements, 'ENV_BASE64_PLACEHOLDER', base64(envContent)))

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    RetentionInDays: 30
  }
}

resource monitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: monitorWorkspaceName
  location: observabilityLocation
}

resource observabilityIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-observability-agent-identity'
  location: observabilityLocation
}

module subscriptionRoles 'observability-sub-roles.bicep' = {
  name: '${prefix}-observability-sub-roles'
  scope: subscription()
  params: {
    principalId: observabilityIdentity.properties.principalId
    prefix: prefix
  }
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, observabilityIdentity.id, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: observabilityIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, observabilityIdentity.id, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: observabilityIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource observabilityAgent 'Microsoft.Monitor/observabilityAgents@2026-05-01-preview' = {
  name: observabilityAgentName
  location: observabilityLocation
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${observabilityIdentity.id}': {}
    }
  }
  tags: {
    purpose: 'Networking observability lab'
    managedBy: 'bicep'
  }
  properties: {
    monitoringAccountId: monitorWorkspace.id
    enabled: true
    operations: [
      {
        type: 'IssueCreation'
        mode: 'Auto'
        instructions: 'Create one issue for related ${prefix}-api-transaction-failures, ${prefix}-api-dependency-failures, ${prefix}-api-dependency-latency, and ${prefix}-api-application-exceptions alerts. Correlate request, dependency, latency, exception, trace, and infrastructure signals only when their operation or timestamps share the same incident window; never merge unrelated profile runs or another deployment prefix. The ${apiRoleName} API runs in spoke11 and depends on Private Endpoint DNS/HTTPS, a cross-hub spoke service, and optionally an on-prem service. Identify failed and healthy dependencies to bound blast radius, distinguish application-only exceptions from network failures, and treat Connection Monitor, VPN, BGP, DNS, NVA, and Application Gateway alerts as possible infrastructure causes.'
      }
      {
        type: 'Investigation'
        mode: 'Auto'
      }
    ]
  }
  dependsOn: [
    reader
    subscriptionRoles
    logAnalyticsReader
  ]
}

resource monitoredApplication 'Microsoft.Monitor/observabilityAgents/monitoredResources@2026-05-01-preview' = {
  parent: observabilityAgent
  name: 'network-transaction-api'
  properties: {
    resourceId: appInsights.id
    enabled: true
    isAutonomous: true
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2als_v7'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'observability-api'
      adminUsername: adminUsername
      adminPassword: empty(adminPassword) ? null : adminPassword
      customData: workloadCloudInit
      linuxConfiguration: useSSHKey
        ? {
            disablePasswordAuthentication: empty(adminPassword)
            ssh: {
              publicKeys: [
                {
                  path: '/home/${adminUsername}/.ssh/authorized_keys'
                  keyData: adminPublicKey
                }
              ]
            }
          }
        : {
            disablePasswordAuthentication: false
          }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource networkWatcherExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'NetworkWatcherAgentLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentLinux'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-observability-ag'
  location: 'global'
  properties: {
    groupShortName: 'ObsAgent'
    enabled: true
    emailReceivers: [
      {
        name: 'Observability-Email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource failedRequestsAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-api-transaction-failures'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-api-transaction-failures'
    description: 'Synthetic API transactions are failing. Investigate application dependencies and the underlying network path.'
    severity: 2
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where cloud_RoleName == "${apiRoleName}" | where success == false'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource failedDependenciesAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-api-dependency-failures'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-api-dependency-failures'
    description: 'One or more synthetic API dependencies are failing. Correlate the target with DNS, routing, VPN, NVA, and on-prem telemetry.'
    severity: 2
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'dependencies | where cloud_RoleName == "${apiRoleName}" | where success == false'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource dependencyLatencyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-api-dependency-latency'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-api-dependency-latency'
    description: 'The targeted synthetic dependency exceeded its expected duration while other dependencies may remain healthy.'
    severity: 3
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'dependencies | where cloud_RoleName == "${apiRoleName}" | where name == "lab.dependency.${dependencyLatencyTarget}" | where duration >= time(${dependencyLatencyAlertThresholdMs}ms)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource applicationExceptionAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-api-application-exceptions'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-api-application-exceptions'
    description: 'The synthetic transaction failed in application code after its dependency checks succeeded.'
    severity: 2
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'exceptions | where cloud_RoleName == "${apiRoleName}" | where type == "ApplicationProfileError" or outerMessage has "application-exception"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output apiVmId string = vm.id
output apiVmName string = vm.name
output apiPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output applicationInsightsId string = appInsights.id
output applicationInsightsName string = appInsights.name
output observabilityAgentId string = observabilityAgent.id
output observabilityAgentName string = observabilityAgent.name
output azureMonitorWorkspaceId string = monitorWorkspace.id
