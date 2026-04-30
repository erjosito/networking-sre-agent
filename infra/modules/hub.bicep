// Hub module: VNet, NVA VM with iptables, Internal LB with HA ports,
// VPN Gateway with BGP, route tables, and NSGs.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Hub identifier (hub1, hub2)')
param hubName string

@description('VNet address space')
param vnetAddressPrefix string

@description('GatewaySubnet prefix (/27)')
param gatewaySubnetPrefix string

@description('NVA subnet prefix (/24)')
param nvaSubnetPrefix string

@description('Default subnet prefix (/24)')
param defaultSubnetPrefix string

@description('VPN Gateway BGP ASN')
param vpnGatewayAsn int

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password (fallback)')
param adminPassword string

@description('SSH public key (preferred)')
param adminPublicKey string

@description('Routes for spoke prefixes to program on GatewaySubnet RT')
param spokeRoutes array

@description('Static private IP for the NVA LB frontend (must be in NVA subnet)')
param nvaLbPrivateIp string

@description('Application Gateway subnet prefix (/24)')
param appGwSubnetPrefix string

@description('Routes for the NVA subnet (cross-hub spoke prefixes via remote NVA LB)')
param nvaSubnetRoutes array = []

@description('Private Endpoint subnet prefix (/24), empty to skip PE subnet')
param privateEndpointSubnetPrefix string = ''

// ──────────────────────────────────────────────
// Variables
// ──────────────────────────────────────────────
var useSSHKey = !empty(adminPublicKey)
var nvaVmName = '${prefix}-${hubName}-nva'
var nvaCloudInit = base64(loadTextContent('../cloud-init/nva.yaml'))

// ──────────────────────────────────────────────
// NSG for NVA Subnet
// ──────────────────────────────────────────────
resource nvaNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-${hubName}-nva-nsg'
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
        name: 'AllowICMP'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowInternalInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// NSG for default subnet
// ──────────────────────────────────────────────
resource defaultNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-${hubName}-default-nsg'
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
        name: 'AllowICMP'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowInternalInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// NSG for AppGwSubnet (requires GatewayManager + AzureLoadBalancer inbound)
// ──────────────────────────────────────────────
resource appGwNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-${hubName}-appgw-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowGatewayManager'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTP'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowInternalInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Route Table for GatewaySubnet (spoke → NVA LB)
// ──────────────────────────────────────────────
resource gwRouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-${hubName}-gw-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      for route in spokeRoutes: {
        name: route.name
        properties: {
          addressPrefix: route.addressPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nvaLbPrivateIp
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Route Table for AppGwSubnet (spoke → NVA LB)
// Ensures AppGW→spoke traffic is symmetric (via NVA)
// ──────────────────────────────────────────────
resource appGwRouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-${hubName}-appgw-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'rfc1918-10'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nvaLbPrivateIp
        }
      }
      {
        name: 'rfc1918-172'
        properties: {
          addressPrefix: '172.16.0.0/12'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nvaLbPrivateIp
        }
      }
      {
        name: 'rfc1918-192'
        properties: {
          addressPrefix: '192.168.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nvaLbPrivateIp
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Route Table for NvaSubnet (cross-hub spoke routes via remote NVA LB)
// ──────────────────────────────────────────────
resource nvaRouteTable 'Microsoft.Network/routeTables@2024-01-01' = if (!empty(nvaSubnetRoutes)) {
  name: '${prefix}-${hubName}-nva-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      for route in nvaSubnetRoutes: {
        name: route.name
        properties: {
          addressPrefix: route.addressPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: route.nextHopIp
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// NAT Gateway for NVA outbound internet
// ──────────────────────────────────────────────
resource natGwPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}-${hubName}-natgw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = {
  name: '${prefix}-${hubName}-natgw'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natGwPip.id
      }
    ]
  }
}

// ──────────────────────────────────────────────
// NSG for Private Endpoint Subnet
// ──────────────────────────────────────────────
resource peNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (!empty(privateEndpointSubnetPrefix)) {
  name: '${prefix}-${hubName}-pe-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowInternalInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Route Table for PE Subnet (return traffic via NVA)
// ──────────────────────────────────────────────
resource peRouteTable 'Microsoft.Network/routeTables@2024-01-01' = if (!empty(privateEndpointSubnetPrefix)) {
  name: '${prefix}-${hubName}-pe-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      for route in spokeRoutes: {
        name: route.name
        properties: {
          addressPrefix: route.addressPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nvaLbPrivateIp
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Virtual Network
// ──────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${prefix}-${hubName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
          routeTable: {
            id: gwRouteTable.id
          }
        }
      }
      {
        name: 'NvaSubnet'
        properties: {
          addressPrefix: nvaSubnetPrefix
          defaultOutboundAccess: false
          natGateway: {
            id: natGateway.id
          }
          networkSecurityGroup: {
            id: nvaNsg.id
          }
          routeTable: !empty(nvaSubnetRoutes) ? {
            id: nvaRouteTable.id
          } : null
        }
      }
      {
        name: 'default'
        properties: {
          addressPrefix: defaultSubnetPrefix
          networkSecurityGroup: {
            id: defaultNsg.id
          }
        }
      }
      {
        name: 'AppGwSubnet'
        properties: {
          addressPrefix: appGwSubnetPrefix
          networkSecurityGroup: {
            id: appGwNsg.id
          }
          routeTable: {
            id: appGwRouteTable.id
          }
        }
      }
    ]
    // PE subnet added conditionally after VNet creation to avoid circular deps
  }
}

// ──────────────────────────────────────────────
// Private Endpoint Subnet (added separately to support conditional creation)
// ──────────────────────────────────────────────
resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (!empty(privateEndpointSubnetPrefix)) {
  parent: vnet
  name: 'PrivateEndpointSubnet'
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Enabled'
    networkSecurityGroup: {
      id: peNsg.id
    }
    routeTable: {
      id: peRouteTable.id
    }
  }
  dependsOn: [
    nvaNsg
    defaultNsg
    appGwNsg
  ]
}

// ──────────────────────────────────────────────
// NVA NIC (IP forwarding enabled)
// ──────────────────────────────────────────────
resource nvaNic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${nvaVmName}-nic'
  location: location
  properties: {
    enableIPForwarding: true
    networkSecurityGroup: {
      id: nvaNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[1].id
          }
          loadBalancerBackendAddressPools: [
            {
              id: internalLb.properties.backendAddressPools[0].id
            }
          ]
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// NVA Virtual Machine
// ──────────────────────────────────────────────
resource nvaVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: nvaVmName
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
      computerName: '${hubName}-nva'
      adminUsername: adminUsername
      adminPassword: empty(adminPassword) ? null : adminPassword
      customData: nvaCloudInit
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
          id: nvaNic.id
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

// Network Watcher Agent extension on NVA VM
resource nvaNetworkWatcherExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: nvaVm
  name: 'NetworkWatcherAgentLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentLinux'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
}

// ──────────────────────────────────────────────
// Internal Load Balancer with HA Ports for NVA
// ──────────────────────────────────────────────
resource internalLb 'Microsoft.Network/loadBalancers@2024-01-01' = {
  name: '${prefix}-${hubName}-nva-lb'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'nva-frontend'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: nvaLbPrivateIp
          subnet: {
            id: vnet.properties.subnets[1].id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'nva-backend'
      }
    ]
    loadBalancingRules: [
      {
        name: 'ha-ports-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${prefix}-${hubName}-nva-lb', 'nva-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${prefix}-${hubName}-nva-lb', 'nva-backend')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${prefix}-${hubName}-nva-lb', 'nva-health-probe')
          }
          protocol: 'All'
          frontendPort: 0
          backendPort: 0
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
    ]
    probes: [
      {
        name: 'nva-health-probe'
        properties: {
          protocol: 'Tcp'
          port: 22
          intervalInSeconds: 15
          numberOfProbes: 2
          probeThreshold: 1
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// VPN Gateway Public IP
// ──────────────────────────────────────────────
resource vpnGwPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}-${hubName}-vpngw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ──────────────────────────────────────────────
// VPN Gateway
// ──────────────────────────────────────────────
resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: '${prefix}-${hubName}-vpngw'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1AZ'
      tier: 'VpnGw1AZ'
    }
    enableBgp: true
    bgpSettings: {
      asn: vpnGatewayAsn
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: vpnGwPip.id
          }
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output vnetName string = vnet.name
output vnetId string = vnet.id
output nvaLbFrontendIp string = nvaLbPrivateIp
output nvaVmId string = nvaVm.id
output vpnGatewayId string = vpnGateway.id
output vpnGatewayPublicIp string = vpnGwPip.properties.ipAddress
output vpnGatewayBgpAddress string = vpnGateway.properties.bgpSettings.bgpPeeringAddress
output appGwSubnetId string = vnet.properties.subnets[3].id
output privateEndpointSubnetId string = !empty(privateEndpointSubnetPrefix) ? peSubnet.id : ''
