// Containerlab Connection Monitor (Part A2 / option T3): probes the in-fabric
// on-prem server (172.31.20.10) FROM the containerlab host VM, so the probe path
// traverses the containerized fabric: clab-host -> r1 (WAN edge) -> eBGP -> r2
// (core) -> onprem-host. Breaking the r1<->r2 BGP session or transit link withdraws
// the LAN route and fails this probe, while the FRR-on-VM tests keep passing —
// letting the SRE Agent localize a control-plane fault to the simulated fabric.
//
// Requires the host-facing probe link wired by onprem.clab.yml + containerlab-host
// cloud-init (172.31.11.0/30, host route to 172.31.20.0/24 via r1), and the
// Network Watcher agent on the clab host VM (added in onprem-containerlab.bicep).
// Deployed to NetworkWatcherRG (where the regional Network Watcher lives).

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Containerlab host VM resource ID (Connection Monitor source)')
param clabVmId string

@description('Containerlab host VM name')
param clabVmName string

@description('Containerlab host VM private IP')
param clabVmIp string

@description('In-fabric on-prem server address reachable through the containerlab data path')
param inFabricServerAddress string = '172.31.20.10'

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

resource networkWatcher 'Microsoft.Network/networkWatchers@2024-01-01' existing = {
  name: 'NetworkWatcher_${location}'
}

resource connectionMonitor 'Microsoft.Network/networkWatchers/connectionMonitors@2024-01-01' = {
  parent: networkWatcher
  name: '${prefix}-clab-connection-monitor'
  location: location
  properties: {
    endpoints: [
      {
        name: clabVmName
        type: 'AzureVM'
        resourceId: clabVmId
        address: clabVmIp
      }
      {
        name: 'onprem-host-in-fabric'
        type: 'ExternalAddress'
        address: inFabricServerAddress
      }
    ]
    testConfigurations: [
      {
        name: 'clab-icmp-test'
        testFrequencySec: 30
        protocol: 'ICMP'
        icmpConfiguration: {}
        successThreshold: {
          checksFailedPercent: 50
          roundTripTimeMs: 200
        }
      }
      {
        name: 'clab-http-test'
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
        name: 'clabhost-to-infabric-server'
        sources: [ clabVmName ]
        destinations: [ 'onprem-host-in-fabric' ]
        testConfigurations: [ 'clab-icmp-test', 'clab-http-test' ]
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
