// On-prem LAN (Stage 1): a new subnet in the EXISTING on-prem VNet that sits
// behind the FRR router, plus the on-prem server target. UDRs force both the
// forward path (LAN default route -> FRR) and the return path (GatewaySubnet ->
// LAN via FRR) through the router, so a router fault breaks the data-plane
// probes to the server. Subnet writes are serialized to avoid concurrent-write
// conflicts on the shared VNet.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Name of the existing on-prem VNet')
param onpremVnetName string = '${prefix}-onprem-vnet'

@description('New on-prem LAN subnet prefix (behind the router)')
param onpremLanSubnetPrefix string = '10.100.2.0/24'

@description('Existing GatewaySubnet prefix (to attach the return-path route table)')
param gatewaySubnetPrefix string = '10.100.0.0/27'

@description('FRR router private IP (UDR next hop)')
param frrPrivateIp string

@description('Telemetry collector IP for syslog forwarding (empty = no forwarding)')
param collectorPrivateIp string = '10.100.1.100'

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password (fallback / serial console)')
param adminPassword string

@description('SSH public key (preferred)')
param adminPublicKey string

var useSSHKey = !empty(adminPublicKey)
var serverVmName = '${prefix}-onprem-server'
var serverCloudInit = base64(replace(loadTextContent('../cloud-init/onprem-server.yaml'), 'COLLECTOR_IP_PLACEHOLDER', collectorPrivateIp))

resource onpremVnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: onpremVnetName
}

// LAN default route -> FRR (forward path). BGP propagation disabled so the LAN
// never learns VPN routes that would bypass the router.
resource lanRouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-onprem-lan-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-frr'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: frrPrivateIp
        }
      }
    ]
  }
}

// Return path: force Azure -> LAN traffic arriving at the VPN gateway through
// the FRR router (mirrors the hub GatewaySubnet -> NVA pattern).
resource gwRouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-onprem-gw-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-lan-via-frr'
        properties: {
          addressPrefix: onpremLanSubnetPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: frrPrivateIp
        }
      }
    ]
  }
}

resource lanNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-onprem-lan-nsg'
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

// New LAN subnet behind the router.
resource lanSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: onpremVnet
  name: 'onprem-lan'
  properties: {
    addressPrefix: onpremLanSubnetPrefix
    networkSecurityGroup: {
      id: lanNsg.id
    }
    routeTable: {
      id: lanRouteTable.id
    }
  }
}

// Attach the return-path route table to the existing GatewaySubnet. Depends on
// lanSubnet so the two subnet writes on the shared VNet do not run concurrently.
resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: onpremVnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: gatewaySubnetPrefix
    routeTable: {
      id: gwRouteTable.id
    }
  }
  dependsOn: [
    lanSubnet
  ]
}

resource serverNic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${serverVmName}-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: lanNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: lanSubnet.id
          }
        }
      }
    ]
  }
}

resource serverVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: serverVmName
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
      computerName: 'onprem-server'
      adminUsername: adminUsername
      adminPassword: empty(adminPassword) ? null : adminPassword
      customData: serverCloudInit
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
          id: serverNic.id
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
  parent: serverVm
  name: 'NetworkWatcherAgentLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentLinux'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
}

output serverVmId string = serverVm.id
output serverVmName string = serverVm.name
output serverPrivateIp string = serverNic.properties.ipConfigurations[0].properties.privateIPAddress
output onpremLanSubnetId string = lanSubnet.id
