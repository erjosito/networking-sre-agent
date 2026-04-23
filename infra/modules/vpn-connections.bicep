// VPN Connections module: Local Network Gateways and S2S VPN connections
// with BGP between on-prem ↔ hub1 and on-prem ↔ hub2.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@secure()
@description('VPN shared key')
param vpnSharedKey string

// Hub 1 VPN Gateway parameters
param hub1VpnGwId string
param hub1VpnGwPublicIp string
param hub1VpnGwBgpAddress string
param hub1VpnGwAsn int

// Hub 2 VPN Gateway parameters
param hub2VpnGwId string
param hub2VpnGwPublicIp string
param hub2VpnGwBgpAddress string
param hub2VpnGwAsn int

// On-prem VPN Gateway parameters
param onpremVpnGwId string
param onpremVpnGwPublicIp string
param onpremVpnGwBgpAddress string
param onpremVpnGwAsn int

// ──────────────────────────────────────────────
// Local Network Gateways
// (Each side needs an LNG representing the remote gateway)
// ──────────────────────────────────────────────

// On-prem side: LNG representing Hub1
resource lngHub1OnOnprem 'Microsoft.Network/localNetworkGateways@2024-01-01' = {
  name: '${prefix}-lng-hub1-on-onprem'
  location: location
  properties: {
    gatewayIpAddress: hub1VpnGwPublicIp
    bgpSettings: {
      asn: hub1VpnGwAsn
      bgpPeeringAddress: hub1VpnGwBgpAddress
    }
    localNetworkAddressSpace: {
      addressPrefixes: []
    }
  }
}

// On-prem side: LNG representing Hub2
resource lngHub2OnOnprem 'Microsoft.Network/localNetworkGateways@2024-01-01' = {
  name: '${prefix}-lng-hub2-on-onprem'
  location: location
  properties: {
    gatewayIpAddress: hub2VpnGwPublicIp
    bgpSettings: {
      asn: hub2VpnGwAsn
      bgpPeeringAddress: hub2VpnGwBgpAddress
    }
    localNetworkAddressSpace: {
      addressPrefixes: []
    }
  }
}

// Hub1 side: LNG representing On-prem
resource lngOnpremOnHub1 'Microsoft.Network/localNetworkGateways@2024-01-01' = {
  name: '${prefix}-lng-onprem-on-hub1'
  location: location
  properties: {
    gatewayIpAddress: onpremVpnGwPublicIp
    bgpSettings: {
      asn: onpremVpnGwAsn
      bgpPeeringAddress: onpremVpnGwBgpAddress
    }
    localNetworkAddressSpace: {
      addressPrefixes: []
    }
  }
}

// Hub2 side: LNG representing On-prem
resource lngOnpremOnHub2 'Microsoft.Network/localNetworkGateways@2024-01-01' = {
  name: '${prefix}-lng-onprem-on-hub2'
  location: location
  properties: {
    gatewayIpAddress: onpremVpnGwPublicIp
    bgpSettings: {
      asn: onpremVpnGwAsn
      bgpPeeringAddress: onpremVpnGwBgpAddress
    }
    localNetworkAddressSpace: {
      addressPrefixes: []
    }
  }
}

// ──────────────────────────────────────────────
// VPN Connections: On-prem → Hub1
// ──────────────────────────────────────────────
resource connOnpremToHub1 'Microsoft.Network/connections@2024-01-01' = {
  name: '${prefix}-conn-onprem-to-hub1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: onpremVpnGwId
      properties: {}
    }
    localNetworkGateway2: {
      id: lngHub1OnOnprem.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    enableBgp: true
    connectionProtocol: 'IKEv2'
  }
}

// ──────────────────────────────────────────────
// VPN Connections: Hub1 → On-prem
// ──────────────────────────────────────────────
resource connHub1ToOnprem 'Microsoft.Network/connections@2024-01-01' = {
  name: '${prefix}-conn-hub1-to-onprem'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: hub1VpnGwId
      properties: {}
    }
    localNetworkGateway2: {
      id: lngOnpremOnHub1.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    enableBgp: true
    connectionProtocol: 'IKEv2'
  }
}

// ──────────────────────────────────────────────
// VPN Connections: On-prem → Hub2
// ──────────────────────────────────────────────
resource connOnpremToHub2 'Microsoft.Network/connections@2024-01-01' = {
  name: '${prefix}-conn-onprem-to-hub2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: onpremVpnGwId
      properties: {}
    }
    localNetworkGateway2: {
      id: lngHub2OnOnprem.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    enableBgp: true
    connectionProtocol: 'IKEv2'
  }
}

// ──────────────────────────────────────────────
// VPN Connections: Hub2 → On-prem
// ──────────────────────────────────────────────
resource connHub2ToOnprem 'Microsoft.Network/connections@2024-01-01' = {
  name: '${prefix}-conn-hub2-to-onprem'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: hub2VpnGwId
      properties: {}
    }
    localNetworkGateway2: {
      id: lngOnpremOnHub2.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    enableBgp: true
    connectionProtocol: 'IKEv2'
  }
}
