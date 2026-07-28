// On-prem Connection Monitor (Stage 1): probes the on-prem server that sits
// BEHIND the FRR router, from a spoke in EACH hub. Both paths reach the server
// via the VPN gateway and the GatewaySubnet UDR -> FRR, so they genuinely
// transit the router: a router/LAN fault fails these probes while the existing
// spoke-to-spoke tests keep passing, letting the SRE Agent localize the fault
// to the on-prem device.
// Deployed to NetworkWatcherRG (where the regional Network Watcher lives).

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('On-prem server (probe target) VM resource ID')
param serverVmId string

@description('On-prem server name')
param serverVmName string

@description('On-prem server private IP')
param serverVmIp string

@description('Hub1 spoke source VM resource ID')
param spokeAVmId string

@description('Hub1 spoke source VM name')
param spokeAVmName string

@description('Hub1 spoke source VM private IP')
param spokeAVmIp string

@description('Hub2 spoke source VM resource ID')
param spokeBVmId string

@description('Hub2 spoke source VM name')
param spokeBVmName string

@description('Hub2 spoke source VM private IP')
param spokeBVmIp string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

resource networkWatcher 'Microsoft.Network/networkWatchers@2024-01-01' existing = {
  name: 'NetworkWatcher_${location}'
}

resource connectionMonitor 'Microsoft.Network/networkWatchers/connectionMonitors@2024-01-01' = {
  parent: networkWatcher
  name: '${prefix}-onprem-connection-monitor'
  location: location
  properties: {
    endpoints: [
      {
        name: spokeAVmName
        type: 'AzureVM'
        resourceId: spokeAVmId
        address: spokeAVmIp
      }
      {
        name: spokeBVmName
        type: 'AzureVM'
        resourceId: spokeBVmId
        address: spokeBVmIp
      }
      {
        name: serverVmName
        type: 'AzureVM'
        resourceId: serverVmId
        address: serverVmIp
      }
    ]
    testConfigurations: [
      {
        name: 'icmp-test'
        testFrequencySec: 30
        protocol: 'ICMP'
        icmpConfiguration: {}
        successThreshold: {
          checksFailedPercent: 50
          roundTripTimeMs: 200
        }
      }
      {
        name: 'http-server-test'
        testFrequencySec: 30
        protocol: 'Http'
        httpConfiguration: {
          port: 80
          method: 'Get'
          path: '/'
          validStatusCodeRanges: [ '200' ]
          preferHTTPS: false
        }
        successThreshold: {
          checksFailedPercent: 50
          roundTripTimeMs: 500
        }
      }
    ]
    testGroups: [
      {
        name: 'hub1-spoke-to-onprem-server'
        sources: [ spokeAVmName ]
        destinations: [ serverVmName ]
        testConfigurations: [ 'icmp-test', 'http-server-test' ]
        disable: false
      }
      {
        name: 'hub2-spoke-to-onprem-server'
        sources: [ spokeBVmName ]
        destinations: [ serverVmName ]
        testConfigurations: [ 'icmp-test', 'http-server-test' ]
        disable: false
      }
    ]
    outputs: [
      {
        type: 'Workspace'
        workspaceSettings: {
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      }
    ]
  }
}

output connectionMonitorId string = connectionMonitor.id
