// On-prem AAA (RADIUS) audit trail -> Log Analytics.
//
// FreeRADIUS on the collector writes an auth log (Login OK / Login incorrect,
// with operator + originating device) to a flat file. This module ships that
// file into a custom OnPremAAA_CL table via AMA custom-text-log ingestion:
//
//   FreeRADIUS radius.log --(AMA text log)--> DCR (transform) --> OnPremAAA_CL
//
// AMA is already installed on the collector by onprem-collector.bicep; here we
// add the Data Collection Endpoint (required for custom text logs), the custom
// table, the text-log DCR with a parsing transform, and the association.

@description('Resource name prefix (matches the rest of the lab).')
param prefix string

@description('Azure region.')
param location string

@description('Full resource ID of the Log Analytics workspace (e.g. <prefix>-law).')
param logAnalyticsWorkspaceId string

@description('Name of the existing collector VM that runs FreeRADIUS + AMA.')
param collectorVmName string = '${prefix}-onprem-collector'

@description('Path of the FreeRADIUS auth log on the collector.')
param radiusLogPath string = '/var/log/freeradius/radius.log'

var lawName = last(split(logAnalyticsWorkspaceId, '/'))
var tableName = 'OnPremAAA_CL'
var streamName = 'Custom-${tableName}'

// Existing collector VM (association scope).
resource collectorVm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: collectorVmName
}

// Custom table that receives the parsed AAA audit records.
resource aaaTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: '${lawName}/${tableName}'
  properties: {
    schema: {
      name: tableName
      columns: [
        {
          name: 'TimeGenerated'
          type: 'datetime'
        }
        {
          name: 'Result'
          type: 'string'
        }
        {
          name: 'Operator'
          type: 'string'
        }
        {
          name: 'ClientHost'
          type: 'string'
        }
        {
          name: 'RawData'
          type: 'string'
        }
      ]
    }
  }
}

// Data Collection Endpoint — required for AMA custom text log ingestion.
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: '${prefix}-onprem-aaa-dce'
  location: location
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Text-log DCR: tail radius.log, parse each auth line into columns, land in the
// custom table. Only Login OK / Login incorrect lines are kept (drops startup
// noise). TimeGenerated is the ingestion time; the device clock is preserved in
// RawData for cross-check.
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${prefix}-onprem-aaa-dcr'
  location: location
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: [
          {
            name: 'TimeGenerated'
            type: 'datetime'
          }
          {
            name: 'RawData'
            type: 'string'
          }
        ]
      }
    }
    dataSources: {
      logFiles: [
        {
          name: 'freeradiusAuth'
          streams: [
            streamName
          ]
          filePatterns: [
            radiusLogPath
          ]
          format: 'text'
          settings: {
            text: {
              recordStartTimestampFormat: 'ISO 8601'
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          streamName
        ]
        destinations: [
          'law'
        ]
        transformKql: 'source | where RawData has "Login OK" or RawData has "Login incorrect" | extend Result = iff(RawData has "Login OK", "Success", "Failure") | parse RawData with * "[" Operator "]" * | parse RawData with * "from client " ClientHost " port" * | project TimeGenerated, Result, Operator, ClientHost, RawData'
        outputStream: streamName
      }
    ]
  }
}

// Associate the DCR with the collector VM so its AMA applies it.
resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${prefix}-onprem-aaa-dcra'
  scope: collectorVm
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

output tableName string = tableName
output dceId string = dce.id
output dcrId string = dcr.id
