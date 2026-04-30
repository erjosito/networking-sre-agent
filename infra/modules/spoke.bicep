// Spoke module: VNet, workload VM, peering to hub, UDR via NVA LB, NSG,
// and Network Watcher Agent extension.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Spoke identifier (spoke11, spoke12, etc.)')
param spokeName string

@description('VNet address space')
param vnetAddressPrefix string

@description('Default subnet prefix (/24)')
param defaultSubnetPrefix string

@description('Hub VNet name for peering')
param hubVnetName string

@description('Hub VNet resource ID for peering')
param hubVnetId string

@description('Hub NVA LB frontend IP for UDR next hop')
param nvaLbFrontendIp string

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password (fallback)')
param adminPassword string

@description('SSH public key (preferred)')
param adminPublicKey string

@description('Additional routes beyond default route (other spokes, on-prem, etc.)')
param additionalRoutes array

@description('Custom DNS server IPs for the spoke VNet (empty = Azure default)')
param dnsServers array = []

// ──────────────────────────────────────────────
// Variables
// ──────────────────────────────────────────────
var useSSHKey = !empty(adminPublicKey)
var vmName = '${prefix}-${spokeName}-vm'
var workloadCloudInit = base64(loadTextContent('../cloud-init/workload.yaml'))
var defaultRoute = [
  {
    name: 'default-to-nva'
    properties: {
      addressPrefix: '0.0.0.0/0'
      nextHopType: 'VirtualAppliance'
      nextHopIpAddress: nvaLbFrontendIp
    }
  }
]
var extraRoutes = [
  for route in additionalRoutes: {
    name: route.name
    properties: {
      addressPrefix: route.addressPrefix
      nextHopType: 'VirtualAppliance'
      nextHopIpAddress: nvaLbFrontendIp
    }
  }
]

// ──────────────────────────────────────────────
// NSG for workload subnet
// ──────────────────────────────────────────────
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-${spokeName}-nsg'
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
// Route Table (0/0 → NVA LB, plus additional routes)
// BGP propagation disabled so spoke always routes through NVA
// ──────────────────────────────────────────────
resource routeTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-${spokeName}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: concat(defaultRoute, extraRoutes)
  }
}

// ──────────────────────────────────────────────
// Virtual Network
// ──────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${prefix}-${spokeName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    dhcpOptions: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: defaultSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// VNet Peering: Spoke → Hub
// ──────────────────────────────────────────────
resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  parent: vnet
  name: '${spokeName}-to-${hubVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}

// ──────────────────────────────────────────────
// VNet Peering: Hub → Spoke
// ──────────────────────────────────────────────
resource hubToSpokePeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${hubVnetName}/${hubVnetName}-to-${spokeName}'
  properties: {
    remoteVirtualNetwork: {
      id: vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

// ──────────────────────────────────────────────
// Workload VM NIC
// ──────────────────────────────────────────────
resource vmNic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
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
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Workload Virtual Machine
// ──────────────────────────────────────────────
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
      computerName: replace(spokeName, '_', '-')
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
          id: vmNic.id
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

// Network Watcher Agent extension on workload VM
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

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output vnetId string = vnet.id
output vmId string = vm.id
output vmName string = vm.name
output vmPrivateIp string = vmNic.properties.ipConfigurations[0].properties.privateIPAddress
