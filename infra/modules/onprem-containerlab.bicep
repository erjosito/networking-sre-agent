// On-prem Containerlab host (Part A2 — high-fidelity simulation).
// A single "beefy" Linux VM running Docker + Containerlab that boots the
// containerized on-prem fabric (infra/containerlab/onprem.clab.yml). This is an
// optional, self-contained add-on: it does not sit in the Azure data path (that
// is Stage 1's FRR-on-VM design); it provides realistic vendor CLIs, syslog and
// (with SR Linux) gNMI/SNMP telemetry from real network-OS containers.

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Subnet resource ID for the host NIC (on-prem default subnet)')
param subnetId string

@description('Telemetry collector IP for host syslog forwarding')
param collectorPrivateIp string = '10.100.1.100'

@description('Git branch of the repo to pull the Containerlab topology from')
param repoBranch string = 'onprem'

@description('VM size — needs enough CPU/RAM to run several NOS containers')
param vmSize string = 'Standard_D4als_v7'

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password (fallback / serial console)')
param adminPassword string

@description('SSH public key (preferred)')
param adminPublicKey string

var useSSHKey = !empty(adminPublicKey)
var vmName = '${prefix}-onprem-clab'
var clabCloudInit = base64(replace(replace(loadTextContent('../cloud-init/containerlab-host.yaml'), 'COLLECTOR_IP_PLACEHOLDER', collectorPrivateIp), 'REPO_BRANCH_PLACEHOLDER', repoBranch))

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${vmName}-nsg'
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
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
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
      vmSize: vmSize
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
        diskSizeGB: 64
      }
    }
    osProfile: {
      computerName: 'onprem-clab'
      adminUsername: adminUsername
      adminPassword: empty(adminPassword) ? null : adminPassword
      customData: clabCloudInit
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

// Network Watcher agent — required for this VM to act as a Connection Monitor
// SOURCE endpoint (probes the in-fabric server through the containerlab data path).
resource nwAgent 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureNetworkWatcherExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentLinux'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
}

output clabVmId string = vm.id
output clabVmName string = vm.name
output clabPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress