// Connection Monitors module: Log Analytics workspace, Connection Monitor with
// ICMP + TCP + HTTP test configurations for all spoke-to-spoke, spoke-to-onprem,
// and private endpoint (static website) paths.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

// VM resource IDs (for AzureVM endpoints)
param spoke11VmId string
param spoke12VmId string
param spoke21VmId string
param spoke22VmId string
param onpremVmId string

// VM names (for endpoint naming)
param spoke11VmName string
param spoke12VmName string
param spoke21VmName string
param spoke22VmName string
param onpremVmName string

// VM private IPs (for endpoint addresses)
param spoke11VmIp string
param spoke12VmIp string
param spoke21VmIp string
param spoke22VmIp string
param onpremVmIp string

@description('Traffic Manager FQDN for HTTP reachability test')
param trafficManagerFqdn string = ''

@description('Storage Account static website FQDN for Private Endpoint HTTP probe')
param staticWebsiteFqdn string = ''

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

// Log Analytics workspace is deployed in the main RG and passed as parameter

// ──────────────────────────────────────────────
// Connection Monitor (deployed under Network Watcher in this RG scope)
// The module is deployed to NetworkWatcherRG from main.bicep
// ──────────────────────────────────────────────
resource networkWatcher 'Microsoft.Network/networkWatchers@2024-01-01' existing = {
  name: 'NetworkWatcher_${location}'
}

resource connectionMonitor 'Microsoft.Network/networkWatchers/connectionMonitors@2024-01-01' = {
  parent: networkWatcher
  name: '${prefix}-connection-monitor'
  location: location
  properties: {
    endpoints: [
      {
        name: spoke11VmName
        type: 'AzureVM'
        resourceId: spoke11VmId
        address: spoke11VmIp
      }
      {
        name: spoke12VmName
        type: 'AzureVM'
        resourceId: spoke12VmId
        address: spoke12VmIp
      }
      {
        name: spoke21VmName
        type: 'AzureVM'
        resourceId: spoke21VmId
        address: spoke21VmIp
      }
      {
        name: spoke22VmName
        type: 'AzureVM'
        resourceId: spoke22VmId
        address: spoke22VmIp
      }
      {
        name: onpremVmName
        type: 'AzureVM'
        resourceId: onpremVmId
        address: onpremVmIp
      }
      ...(empty(trafficManagerFqdn) ? [] : [
        {
          name: 'webapp-tm'
          type: 'ExternalAddress'
          address: trafficManagerFqdn
        }
      ])
      {
        name: 'ifconfig-me'
        type: 'ExternalAddress'
        address: 'ifconfig.me'
      }
      ...(empty(staticWebsiteFqdn) ? [] : [
        {
          name: 'staticweb-pe'
          type: 'ExternalAddress'
          address: staticWebsiteFqdn
        }
      ])
    ]
    testConfigurations: [
      {
        name: 'icmp-test'
        testFrequencySec: 30
        protocol: 'ICMP'
        icmpConfiguration: {}
        successThreshold: {
          checksFailedPercent: 50
          roundTripTimeMs: 100
        }
      }
      {
        name: 'tcp-ssh-test'
        testFrequencySec: 60
        protocol: 'Tcp'
        tcpConfiguration: {
          port: 22
        }
        successThreshold: {
          checksFailedPercent: 50
          roundTripTimeMs: 200
        }
      }
      {
        name: 'http-web-test'
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
      {
        name: 'http-pe-test'
        testFrequencySec: 60
        protocol: 'Http'
        httpConfiguration: {
          port: 443
          method: 'Get'
          path: '/'
          validStatusCodeRanges: [ '200' ]
          preferHTTPS: true
        }
        successThreshold: {
          checksFailedPercent: 50
          roundTripTimeMs: 500
        }
      }
    ]
    testGroups: [
      {
        name: 'spoke11-to-spoke12'
        sources: [ spoke11VmName ]
        destinations: [ spoke12VmName ]
        testConfigurations: [ 'icmp-test', 'tcp-ssh-test', 'http-web-test' ]
        disable: false
      }
      {
        name: 'spoke11-to-spoke21'
        sources: [ spoke11VmName ]
        destinations: [ spoke21VmName ]
        testConfigurations: [ 'icmp-test', 'tcp-ssh-test', 'http-web-test' ]
        disable: false
      }
      {
        name: 'spoke11-to-onprem'
        sources: [ spoke11VmName ]
        destinations: [ onpremVmName ]
        testConfigurations: [ 'icmp-test', 'tcp-ssh-test' ]
        disable: false
      }
      {
        name: 'spoke21-to-spoke22'
        sources: [ spoke21VmName ]
        destinations: [ spoke22VmName ]
        testConfigurations: [ 'icmp-test', 'tcp-ssh-test', 'http-web-test' ]
        disable: false
      }
      {
        name: 'spoke21-to-spoke11'
        sources: [ spoke21VmName ]
        destinations: [ spoke11VmName ]
        testConfigurations: [ 'icmp-test', 'tcp-ssh-test', 'http-web-test' ]
        disable: false
      }
      {
        name: 'spoke22-to-onprem'
        sources: [ spoke22VmName ]
        destinations: [ onpremVmName ]
        testConfigurations: [ 'icmp-test', 'tcp-ssh-test' ]
        disable: false
      }
      ...(empty(trafficManagerFqdn) ? [] : [
        {
          name: 'onprem-to-webapp'
          sources: [ onpremVmName ]
          destinations: [ 'webapp-tm' ]
          testConfigurations: [ 'http-web-test' ]
          disable: false
        }
      ])
      {
        name: 'spokes-to-internet'
        sources: [ spoke11VmName, spoke12VmName, spoke21VmName, spoke22VmName ]
        destinations: [ 'ifconfig-me' ]
        testConfigurations: [ 'http-web-test' ]
        disable: false
      }
      ...(empty(staticWebsiteFqdn) ? [] : [
        {
          name: 'spoke11-to-staticweb'
          sources: [ spoke11VmName ]
          destinations: [ 'staticweb-pe' ]
          testConfigurations: [ 'http-pe-test' ]
          disable: false
        }
        {
          name: 'spoke21-to-staticweb'
          sources: [ spoke21VmName ]
          destinations: [ 'staticweb-pe' ]
          testConfigurations: [ 'http-pe-test' ]
          disable: false
        }
        {
          name: 'onprem-to-staticweb'
          sources: [ onpremVmName ]
          destinations: [ 'staticweb-pe' ]
          testConfigurations: [ 'http-pe-test' ]
          disable: false
        }
      ])
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

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output connectionMonitorId string = connectionMonitor.id
