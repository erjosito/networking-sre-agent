// Main orchestrator for Azure Networking Test Environment
// Deploys: 2 hubs with NVAs + VPN GWs, 4 spokes, 1 on-prem sim, VPN connections,
// connection monitors, and alert rules.

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Resource naming prefix')
param prefix string = 'netsre'

@description('Admin username for all VMs')
param adminUsername string = 'azureuser'

@secure()
@description('Admin password for VM serial console access (always set alongside SSH key)')
param adminPassword string = ''

@description('SSH public key for VM authentication (preferred over password)')
param adminPublicKey string = ''

@description('Email address for alert notifications')
param alertEmail string = 'netops@example.com'

@description('VPN shared key for all S2S connections')
@secure()
param vpnSharedKey string

// ──────────────────────────────────────────────
// Hub 1
// ──────────────────────────────────────────────
module hub1 'modules/hub.bicep' = {
  name: 'hub1-deployment'
  params: {
    location: location
    prefix: prefix
    hubName: 'hub1'
    vnetAddressPrefix: '10.1.0.0/16'
    gatewaySubnetPrefix: '10.1.0.0/27'
    nvaSubnetPrefix: '10.1.1.0/24'
    defaultSubnetPrefix: '10.1.2.0/24'
    vpnGatewayAsn: 65001
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    spokeRoutes: [
      { name: 'to-spoke11', addressPrefix: '10.11.0.0/16' }
      { name: 'to-spoke12', addressPrefix: '10.12.0.0/16' }
      { name: 'to-spoke21', addressPrefix: '10.21.0.0/16' }
      { name: 'to-spoke22', addressPrefix: '10.22.0.0/16' }
      { name: 'to-onprem', addressPrefix: '10.100.0.0/16' }
      { name: 'to-pe-subnet', addressPrefix: '10.1.4.0/24' }
    ]
    nvaLbPrivateIp: '10.1.1.200'
    appGwSubnetPrefix: '10.1.3.0/24'
    privateEndpointSubnetPrefix: '10.1.4.0/24'
    nvaSubnetRoutes: [
      { name: 'to-spoke21-via-hub2', addressPrefix: '10.21.0.0/16', nextHopIp: '10.2.1.200' }
      { name: 'to-spoke22-via-hub2', addressPrefix: '10.22.0.0/16', nextHopIp: '10.2.1.200' }
    ]
  }
}

// ──────────────────────────────────────────────
// Hub 2
// ──────────────────────────────────────────────
module hub2 'modules/hub.bicep' = {
  name: 'hub2-deployment'
  params: {
    location: location
    prefix: prefix
    hubName: 'hub2'
    vnetAddressPrefix: '10.2.0.0/16'
    gatewaySubnetPrefix: '10.2.0.0/27'
    nvaSubnetPrefix: '10.2.1.0/24'
    defaultSubnetPrefix: '10.2.2.0/24'
    vpnGatewayAsn: 65002
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    spokeRoutes: [
      { name: 'to-spoke11', addressPrefix: '10.11.0.0/16' }
      { name: 'to-spoke12', addressPrefix: '10.12.0.0/16' }
      { name: 'to-spoke21', addressPrefix: '10.21.0.0/16' }
      { name: 'to-spoke22', addressPrefix: '10.22.0.0/16' }
      { name: 'to-onprem', addressPrefix: '10.100.0.0/16' }
      { name: 'to-pe-subnet', addressPrefix: '10.1.4.0/24' }
    ]
    nvaLbPrivateIp: '10.2.1.200'
    appGwSubnetPrefix: '10.2.3.0/24'
    nvaSubnetRoutes: [
      { name: 'to-spoke11-via-hub1', addressPrefix: '10.11.0.0/16', nextHopIp: '10.1.1.200' }
      { name: 'to-spoke12-via-hub1', addressPrefix: '10.12.0.0/16', nextHopIp: '10.1.1.200' }
    ]
  }
}

// ──────────────────────────────────────────────
// Hub-to-Hub VNet Peering
// ──────────────────────────────────────────────
resource hub1ToHub2Peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${prefix}-hub1-vnet/${prefix}-hub1-vnet-to-${prefix}-hub2-vnet'
  properties: {
    remoteVirtualNetwork: {
      id: hub2.outputs.vnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource hub2ToHub1Peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${prefix}-hub2-vnet/${prefix}-hub2-vnet-to-${prefix}-hub1-vnet'
  properties: {
    remoteVirtualNetwork: {
      id: hub1.outputs.vnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ──────────────────────────────────────────────
// Spokes for Hub 1
// ──────────────────────────────────────────────
module spoke11 'modules/spoke.bicep' = {
  name: 'spoke11-deployment'
  params: {
    location: location
    prefix: prefix
    spokeName: 'spoke11'
    vnetAddressPrefix: '10.11.0.0/16'
    defaultSubnetPrefix: '10.11.0.0/24'
    hubVnetName: hub1.outputs.vnetName
    hubVnetId: hub1.outputs.vnetId
    nvaLbFrontendIp: hub1.outputs.nvaLbFrontendIp
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    additionalRoutes: [
      { name: 'to-pe-subnet', addressPrefix: '10.1.4.0/24' }
    ]
    dnsServers: [ hub1.outputs.nvaLbFrontendIp ]
  }
}

module spoke12 'modules/spoke.bicep' = {
  name: 'spoke12-deployment'
  params: {
    location: location
    prefix: prefix
    spokeName: 'spoke12'
    vnetAddressPrefix: '10.12.0.0/16'
    defaultSubnetPrefix: '10.12.0.0/24'
    hubVnetName: hub1.outputs.vnetName
    hubVnetId: hub1.outputs.vnetId
    nvaLbFrontendIp: hub1.outputs.nvaLbFrontendIp
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    additionalRoutes: [
      { name: 'to-pe-subnet', addressPrefix: '10.1.4.0/24' }
    ]
    dnsServers: [ hub1.outputs.nvaLbFrontendIp ]
  }
}

// ──────────────────────────────────────────────
// Spokes for Hub 2
// ──────────────────────────────────────────────
module spoke21 'modules/spoke.bicep' = {
  name: 'spoke21-deployment'
  params: {
    location: location
    prefix: prefix
    spokeName: 'spoke21'
    vnetAddressPrefix: '10.21.0.0/16'
    defaultSubnetPrefix: '10.21.0.0/24'
    hubVnetName: hub2.outputs.vnetName
    hubVnetId: hub2.outputs.vnetId
    nvaLbFrontendIp: hub2.outputs.nvaLbFrontendIp
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    additionalRoutes: [
      { name: 'to-pe-subnet', addressPrefix: '10.1.4.0/24' }
    ]
    dnsServers: [ hub2.outputs.nvaLbFrontendIp ]
  }
}

module spoke22 'modules/spoke.bicep' = {
  name: 'spoke22-deployment'
  params: {
    location: location
    prefix: prefix
    spokeName: 'spoke22'
    vnetAddressPrefix: '10.22.0.0/16'
    defaultSubnetPrefix: '10.22.0.0/24'
    hubVnetName: hub2.outputs.vnetName
    hubVnetId: hub2.outputs.vnetId
    nvaLbFrontendIp: hub2.outputs.nvaLbFrontendIp
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    additionalRoutes: [
      { name: 'to-pe-subnet', addressPrefix: '10.1.4.0/24' }
    ]
    dnsServers: [ hub2.outputs.nvaLbFrontendIp ]
  }
}

// ──────────────────────────────────────────────
// On-premises simulation
// ──────────────────────────────────────────────
module onprem 'modules/onprem.bicep' = {
  name: 'onprem-deployment'
  params: {
    location: location
    prefix: prefix
    vnetAddressPrefix: '10.100.0.0/16'
    gatewaySubnetPrefix: '10.100.0.0/27'
    defaultSubnetPrefix: '10.100.1.0/24'
    vpnGatewayAsn: 65100
    adminUsername: adminUsername
    adminPassword: adminPassword
    adminPublicKey: adminPublicKey
    dnsServers: [hub1.outputs.nvaLbFrontendIp, hub2.outputs.nvaLbFrontendIp]
  }
}

// ──────────────────────────────────────────────
// VPN Site-to-Site Connections
// ──────────────────────────────────────────────
module vpnConnections 'modules/vpn-connections.bicep' = {
  name: 'vpn-connections-deployment'
  params: {
    location: location
    prefix: prefix
    vpnSharedKey: vpnSharedKey
    hub1VpnGwId: hub1.outputs.vpnGatewayId
    hub1VpnGwPublicIp: hub1.outputs.vpnGatewayPublicIp
    hub1VpnGwBgpAddress: hub1.outputs.vpnGatewayBgpAddress
    hub1VpnGwAsn: 65001
    hub2VpnGwId: hub2.outputs.vpnGatewayId
    hub2VpnGwPublicIp: hub2.outputs.vpnGatewayPublicIp
    hub2VpnGwBgpAddress: hub2.outputs.vpnGatewayBgpAddress
    hub2VpnGwAsn: 65002
    onpremVpnGwId: onprem.outputs.vpnGatewayId
    onpremVpnGwPublicIp: onprem.outputs.vpnGatewayPublicIp
    onpremVpnGwBgpAddress: onprem.outputs.vpnGatewayBgpAddress
    onpremVpnGwAsn: 65100
  }
}

// ──────────────────────────────────────────────
// Log Analytics Workspace (in main RG)
// ──────────────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ──────────────────────────────────────────────
// Private Link (Storage Account Static Website with Private Endpoint in Hub1)
// ──────────────────────────────────────────────
module privateLink 'modules/private-link.bicep' = {
  name: 'private-link-deployment'
  params: {
    location: location
    prefix: prefix
    privateEndpointSubnetId: hub1.outputs.privateEndpointSubnetId
    vnetLinks: [
      { name: 'hub1', vnetId: hub1.outputs.vnetId }
      { name: 'hub2', vnetId: hub2.outputs.vnetId }
    ]
  }
}

// ──────────────────────────────────────────────
// Connection Monitors (deployed to NetworkWatcherRG where Network Watcher lives)
// ──────────────────────────────────────────────
module connectionMonitors 'modules/connection-monitors.bicep' = {
  name: 'connection-monitors-deployment'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    location: location
    prefix: prefix
    spoke11VmId: spoke11.outputs.vmId
    spoke12VmId: spoke12.outputs.vmId
    spoke21VmId: spoke21.outputs.vmId
    spoke22VmId: spoke22.outputs.vmId
    onpremVmId: onprem.outputs.vmId
    spoke11VmName: spoke11.outputs.vmName
    spoke12VmName: spoke12.outputs.vmName
    spoke21VmName: spoke21.outputs.vmName
    spoke22VmName: spoke22.outputs.vmName
    onpremVmName: onprem.outputs.vmName
    spoke11VmIp: spoke11.outputs.vmPrivateIp
    spoke12VmIp: spoke12.outputs.vmPrivateIp
    spoke21VmIp: spoke21.outputs.vmPrivateIp
    spoke22VmIp: spoke22.outputs.vmPrivateIp
    onpremVmIp: onprem.outputs.vmPrivateIp
    trafficManagerFqdn: trafficManager.outputs.trafficManagerFqdn
    staticWebsiteFqdn: privateLink.outputs.staticWebsiteFqdn
    logAnalyticsWorkspaceId: logAnalytics.id
  }
  dependsOn: [
    vpnConnections
  ]
}

// ──────────────────────────────────────────────
// Alert Rules
// ──────────────────────────────────────────────
module alerts 'modules/alerts.bicep' = {
  name: 'alerts-deployment'
  params: {
    prefix: prefix
    alertEmail: alertEmail
    connectionMonitorId: connectionMonitors.outputs.connectionMonitorId
  }
}

// ──────────────────────────────────────────────
// Application Gateways (one per hub)
// ──────────────────────────────────────────────
module appGw1 'modules/appgw.bicep' = {
  name: 'appgw1-deployment'
  params: {
    location: location
    prefix: prefix
    hubName: 'hub1'
    appGwSubnetId: hub1.outputs.appGwSubnetId
    backendIpAddresses: [
      spoke11.outputs.vmPrivateIp
      spoke12.outputs.vmPrivateIp
    ]
  }
}

module appGw2 'modules/appgw.bicep' = {
  name: 'appgw2-deployment'
  params: {
    location: location
    prefix: prefix
    hubName: 'hub2'
    appGwSubnetId: hub2.outputs.appGwSubnetId
    backendIpAddresses: [
      spoke21.outputs.vmPrivateIp
      spoke22.outputs.vmPrivateIp
    ]
  }
}

// ──────────────────────────────────────────────
// Traffic Manager (DNS load balancing across hubs)
// ──────────────────────────────────────────────
module trafficManager 'modules/traffic-manager.bicep' = {
  name: 'traffic-manager-deployment'
  params: {
    prefix: prefix
    hub1AppGwPipResourceId: appGw1.outputs.appGwPipResourceId
    hub2AppGwPipResourceId: appGw2.outputs.appGwPipResourceId
  }
}

// ──────────────────────────────────────────────
// SRE Agent (Azure Networking specialist)
// ──────────────────────────────────────────────
@description('Deploy the SRE Agent for automated incident detection and troubleshooting')
param deploySreAgent bool = true

@description('SRE Agent access level: High (Contributor) or Low (Reader)')
@allowed(['High', 'Low'])
param sreAgentAccessLevel string = 'High'

@description('SRE Agent mode: Review (propose+approve), Autonomous, or ReadOnly')
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param sreAgentMode string = 'Review'

@description('Microsoft Entra group ID whose members can manage the SRE Agent (required when deploySreAgent=true)')
param sreAgentSponsorGroupId string = ''

module sreAgent 'modules/sre-agent.bicep' = if (deploySreAgent) {
  name: 'sre-agent-deployment'
  params: {
    location: location
    prefix: prefix
    accessLevel: sreAgentAccessLevel
    agentMode: sreAgentMode
    initialSponsorGroupId: sreAgentSponsorGroupId
    managedResourceGroupIds: [
      resourceGroup().id
    ]
    logAnalyticsWorkspaceId: logAnalytics.id
  }
  dependsOn: [
    hub1
    hub2
    onprem
    connectionMonitors
    alerts
  ]
}

// Subscription-scoped: Monitoring Contributor for the SRE Agent
module sreAgentSubRoles 'modules/sre-agent-sub-roles.bicep' = if (deploySreAgent) {
  name: 'sre-agent-sub-roles-deployment'
  scope: subscription()
  params: {
    principalId: deploySreAgent ? sreAgent.outputs.managedIdentityPrincipalId : ''
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output hub1VnetId string = hub1.outputs.vnetId
output hub2VnetId string = hub2.outputs.vnetId
output spoke11VmPrivateIp string = spoke11.outputs.vmPrivateIp
output spoke12VmPrivateIp string = spoke12.outputs.vmPrivateIp
output spoke21VmPrivateIp string = spoke21.outputs.vmPrivateIp
output spoke22VmPrivateIp string = spoke22.outputs.vmPrivateIp
output onpremVmPrivateIp string = onprem.outputs.vmPrivateIp
output connectionMonitorId string = connectionMonitors.outputs.connectionMonitorId
output hub1AppGwPublicIp string = appGw1.outputs.appGwPublicIp
output hub2AppGwPublicIp string = appGw2.outputs.appGwPublicIp
output trafficManagerFqdn string = trafficManager.outputs.trafficManagerFqdn
output sreAgentId string = deploySreAgent ? sreAgent.outputs.agentId : ''
output sreAgentName string = deploySreAgent ? sreAgent.outputs.agentName : ''
output sreAgentPortalUrl string = deploySreAgent ? sreAgent.outputs.agentPortalUrl : ''
output sreAgentManagedIdentityId string = deploySreAgent ? sreAgent.outputs.managedIdentityId : ''
