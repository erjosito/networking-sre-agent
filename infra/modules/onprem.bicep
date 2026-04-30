// On-premises simulation module: VNet, VPN Gateway with BGP, test VM, NSG,
// and Network Watcher Agent extension.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('VNet address space')
param vnetAddressPrefix string

@description('GatewaySubnet prefix (/27)')
param gatewaySubnetPrefix string

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

@description('Custom DNS servers for VNet (NVA LB IPs)')
param dnsServers array = []

// ──────────────────────────────────────────────
// Variables
// ──────────────────────────────────────────────
var useSSHKey = !empty(adminPublicKey)
var vmName = '${prefix}-onprem-vm'
var workloadCloudInit = base64(loadTextContent('../cloud-init/workload.yaml'))

// ──────────────────────────────────────────────
// NSG
// ──────────────────────────────────────────────
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-onprem-nsg'
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
// NAT Gateway for outbound internet (needed for CM to external endpoints)
// ──────────────────────────────────────────────
resource natGwPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}-onprem-natgw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-01-01' = {
  name: '${prefix}-onprem-natgw'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      { id: natGwPip.id }
    ]
    idleTimeoutInMinutes: 4
  }
}

// ──────────────────────────────────────────────
// Virtual Network
// ──────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${prefix}-onprem-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    dhcpOptions: !empty(dnsServers) ? {
      dnsServers: dnsServers
    } : null
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
      {
        name: 'default'
        properties: {
          addressPrefix: defaultSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          natGateway: {
            id: natGw.id
          }
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Test VM NIC
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
            id: vnet.properties.subnets[1].id
          }
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Test Virtual Machine
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
      computerName: 'onprem-vm'
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

// Network Watcher Agent extension on test VM
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
// VPN Gateway Public IP
// ──────────────────────────────────────────────
resource vpnGwPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}-onprem-vpngw-pip'
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
  name: '${prefix}-onprem-vpngw'
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
output vnetId string = vnet.id
output vmId string = vm.id
output vmName string = vm.name
output vmPrivateIp string = vmNic.properties.ipConfigurations[0].properties.privateIPAddress
output vpnGatewayId string = vpnGateway.id
output vpnGatewayPublicIp string = vpnGwPip.properties.ipAddress
output vpnGatewayBgpAddress string = vpnGateway.properties.bgpSettings.bgpPeeringAddress
