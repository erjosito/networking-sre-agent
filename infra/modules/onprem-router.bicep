// On-prem FRR router (Stage 1): a single-NIC "router-on-a-stick" NVA that acts
// as the L3 gateway for the on-prem LAN. IP forwarding is enabled at both the
// NIC and OS level so LAN <-> Azure traffic transits this box; breaking it
// breaks the data-plane probes to the on-prem server.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Subnet resource ID for the router NIC (on-prem default subnet, the WAN side)')
param subnetId string

@description('Static private IP for the FRR router (LAN UDR next hop)')
param frrPrivateIp string = '10.100.1.201'

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
var vmName = '${prefix}-onprem-frr'
var frrCloudInit = base64(replace(loadTextContent('../cloud-init/frr-router.yaml'), 'COLLECTOR_IP_PLACEHOLDER', collectorPrivateIp))

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-onprem-frr-nsg'
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

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    enableIPForwarding: true
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: frrPrivateIp
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
      computerName: 'onprem-frr'
      adminUsername: adminUsername
      adminPassword: empty(adminPassword) ? null : adminPassword
      customData: frrCloudInit
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

output frrVmId string = vm.id
output frrVmName string = vm.name
output frrPrivateIp string = frrPrivateIp
