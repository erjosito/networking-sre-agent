// Private Link module: Storage Account with Static Website, Private Endpoint (web sub-resource),
// Private DNS Zone, and VNet links for DNS resolution across hub-spoke topology.
// The static website serves an index.html used by Connection Monitor HTTP probes.
//
// NOTE: After deploying this module, run the post-deployment step in deploy.ps1
// to enable static website and upload index.html (deployment scripts can't be used
// because the subscription policy blocks key-based auth on storage accounts, which
// the deployment scripts service requires internally).

@description('Azure region')
param location string

@description('Resource naming prefix')
param prefix string

@description('Private Endpoint subnet ID (must have privateEndpointNetworkPolicies enabled)')
param privateEndpointSubnetId string

@description('VNet IDs to link to the Private DNS Zone (hub VNets only)')
param vnetLinks array

// ──────────────────────────────────────────────
// Storage Account with Static Website
// ──────────────────────────────────────────────
// Storage account names: lowercase alphanumeric only, 3-24 chars
var uniqueSuffix = uniqueString(resourceGroup().id, prefix)
var saName = toLower('${replace(prefix, '-', '')}web${take(uniqueSuffix, 8)}')

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// ──────────────────────────────────────────────
// Private DNS Zone
// ──────────────────────────────────────────────
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.web.core.windows.net'
  location: 'global'
}

// Link DNS zone to each VNet
@batchSize(1)
resource dnsVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (link, i) in vnetLinks: {
    parent: privateDnsZone
    name: '${link.name}-link'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: link.vnetId
      }
      registrationEnabled: false
    }
  }
]

// ──────────────────────────────────────────────
// Private Endpoint (web sub-resource)
// ──────────────────────────────────────────────
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: '${prefix}-hub1-web-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-web-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'web'
          ]
        }
      }
    ]
  }
}

// Auto-register DNS record in Private DNS Zone
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-web-core-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output storageAccountName string = storageAccount.name
output staticWebsiteFqdn string = replace(replace(storageAccount.properties.primaryEndpoints.web, 'https://', ''), '/', '')
output privateEndpointName string = privateEndpoint.name
output privateEndpointId string = privateEndpoint.id
output privateDnsZoneName string = privateDnsZone.name
