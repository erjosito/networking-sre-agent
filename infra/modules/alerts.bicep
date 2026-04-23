// Alerts module: Action Group and metric alert rules for Connection Monitor
// checks-failed percentage.

@description('Resource naming prefix')
param prefix string

@description('Email address for alert notifications')
param alertEmail string

@description('Connection Monitor resource ID to monitor')
param connectionMonitorId string

// ──────────────────────────────────────────────
// Action Group
// ──────────────────────────────────────────────
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-netops-ag'
  location: 'global'
  properties: {
    groupShortName: 'NetOps'
    enabled: true
    emailReceivers: [
      {
        name: 'NetOps-Email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Metric Alert: Checks Failed Percent > 50%
// ──────────────────────────────────────────────
resource checksFailedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-conn-monitor-checks-failed'
  location: 'global'
  properties: {
    description: 'Alert when Connection Monitor checks failed percentage exceeds 50%'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      connectionMonitorId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ChecksFailedPercent'
          metricName: 'ChecksFailedPercent'
          metricNamespace: 'Microsoft.Network/networkWatchers/connectionMonitors'
          operator: 'GreaterThan'
          threshold: 50
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output actionGroupId string = actionGroup.id
output alertRuleId string = checksFailedAlert.id
