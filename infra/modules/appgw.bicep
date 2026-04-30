param location string
param prefix string
param hubName string
param appGwSubnetId string
param backendIpAddresses array

var appGwName = '${prefix}-${hubName}-appgw'
var pipName = '${prefix}-${hubName}-appgw-pip'
var dnsSuffix = substring(uniqueString(resourceGroup().id), 0, 6)

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${prefix}-${hubName}-appgw-${dnsSuffix}'
    }
  }
}

resource appGw 'Microsoft.Network/applicationGateways@2024-01-01' = {
  name: appGwName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appgw-ip-config'
        properties: {
          subnet: {
            id: appGwSubnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appgw-feip'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'appgw-feport'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'appgw-bepool'
        properties: {
          backendAddresses: [for ip in backendIpAddresses: {
            ipAddress: ip
          }]
        }
      }
    ]
    probes: [
      {
        name: 'appgw-probe'
        properties: {
          protocol: 'Http'
          path: '/'
          interval: 30
          timeout: 60
          unhealthyThreshold: 3
          minServers: 0
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [ '200-399' ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'appgw-http-settings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 60
          pickHostNameFromBackendAddress: true
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'appgw-probe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'appgw-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appgw-feip')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'appgw-feport')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'appgw-rule'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'appgw-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'appgw-bepool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'appgw-http-settings')
          }
        }
      }
    ]
  }
}

output appGwPublicIp string = pip.properties.ipAddress
output appGwPipResourceId string = pip.id
output appGwId string = appGw.id
output appGwName string = appGw.name
