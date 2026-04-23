param prefix string
param hub1AppGwPipResourceId string
param hub2AppGwPipResourceId string

var dnsSuffix = substring(uniqueString(resourceGroup().id), 0, 6)

resource trafficManagerProfile 'Microsoft.Network/trafficManagerProfiles@2022-04-01' = {
  name: '${prefix}-webapp'
  location: 'global'
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Performance'
    dnsConfig: {
      relativeName: '${prefix}-webapp-${dnsSuffix}'
      ttl: 30
    }
    monitorConfig: {
      protocol: 'HTTP'
      port: 80
      path: '/'
      intervalInSeconds: 30
      timeoutInSeconds: 10
      toleratedNumberOfFailures: 3
    }
  }
}

resource hub1Endpoint 'Microsoft.Network/trafficManagerProfiles/azureEndpoints@2022-04-01' = {
  name: 'hub1-endpoint'
  parent: trafficManagerProfile
  properties: {
    targetResourceId: hub1AppGwPipResourceId
    endpointStatus: 'Enabled'
    weight: 1
    priority: 1
  }
}

resource hub2Endpoint 'Microsoft.Network/trafficManagerProfiles/azureEndpoints@2022-04-01' = {
  name: 'hub2-endpoint'
  parent: trafficManagerProfile
  properties: {
    targetResourceId: hub2AppGwPipResourceId
    endpointStatus: 'Enabled'
    weight: 1
    priority: 2
  }
}

output trafficManagerFqdn string = trafficManagerProfile.properties.dnsConfig.fqdn
output trafficManagerId string = trafficManagerProfile.id
