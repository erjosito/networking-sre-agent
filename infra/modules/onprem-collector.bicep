// On-prem telemetry collector (Stage 0): a Linux VM running rsyslog + Azure
// Monitor Agent (Syslog DCR -> Log Analytics) and Telegraf (SNMP -> Azure
// Monitor custom metrics via managed identity). Devices forward syslog to this
// VM's static private IP; AMA ships it to the existing workspace.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Subnet resource ID to place the collector NIC in (on-prem default subnet)')
param subnetId string

@description('Static private IP for the collector (devices forward syslog here)')
param collectorPrivateIp string = '10.100.1.100'

@description('Log Analytics Workspace resource ID (reuse the lab workspace)')
param logAnalyticsWorkspaceId string

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password (fallback / serial console)')
param adminPassword string

@description('SSH public key (preferred)')
param adminPublicKey string

var useSSHKey = !empty(adminPublicKey)
var vmName = '${prefix}-onprem-collector'
var collectorCloudInit = base64(loadTextContent('../cloud-init/collector.yaml'))
// Monitoring Metrics Publisher (for Telegraf azure_monitor custom metrics)
var metricsPublisherRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4751-9f7b-2dcbc1f3d86b')

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-onprem-collector-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSyslogUdp'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '514'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSyslogTcp'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '514'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: collectorPrivateIp
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
  identity: {
    type: 'SystemAssigned'
  }
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
      computerName: 'onprem-collector'
      adminUsername: adminUsername
      adminPassword: empty(adminPassword) ? null : adminPassword
      customData: collectorCloudInit
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

// Azure Monitor Agent — ships the Syslog stream to Log Analytics.
resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.29'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Data Collection Rule: collect all Linux syslog facilities -> workspace.
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${prefix}-onprem-syslog-dcr'
  location: location
  kind: 'Linux'
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'syslogBase'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            '*'
          ]
          logLevels: [
            '*'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'law'
        ]
      }
    ]
  }
}

// Associate the DCR with the collector VM so AMA applies it.
resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${prefix}-onprem-syslog-dcra'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

// Allow Telegraf (running as the VM identity) to publish custom metrics.
resource metricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, metricsPublisherRoleId)
  scope: vm
  properties: {
    roleDefinitionId: metricsPublisherRoleId
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output collectorVmId string = vm.id
output collectorVmName string = vm.name
output collectorPrivateIp string = collectorPrivateIp
output collectorIdentityPrincipalId string = vm.identity.principalId
