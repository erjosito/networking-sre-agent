// Alerts module: Action Group and metric alert rules for Connection Monitor.
// Fires when any test fails or latency degrades — the SRE Agent picks these up
// automatically via its Azure Monitor connector.

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
// Alert 1: Checks Failed Percent > 20%
// VPN paths have natural jitter, so use a wider window and higher threshold
// to avoid false positives from transient packet loss.
// ──────────────────────────────────────────────
resource checksFailedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-cm-checks-failed'
  location: 'global'
  properties: {
    description: 'Connection Monitor: more than 20% of probes are failing (sustained over 5 min)'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
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
          threshold: 20
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
// Alert 2: Test Result = Fail (sustained)
// TestResult metric values: 0=Indeterminate, 1=Pass, 2=Warning, 3=Fail.
// Fire when tests consistently report Fail over a 5-minute window.
// ──────────────────────────────────────────────
resource testResultAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-cm-test-result-fail'
  location: 'global'
  properties: {
    description: 'Connection Monitor: one or more tests report unreachable destination sustained over 5 min (TestResult=Fail)'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      connectionMonitorId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'TestResultFail'
          metricName: 'TestResult'
          metricNamespace: 'Microsoft.Network/networkWatchers/connectionMonitors'
          operator: 'GreaterThanOrEqual'
          threshold: 3
          timeAggregation: 'Minimum'
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
// Alert 3: Round-Trip Time > 500 ms
// Informational — VPN paths naturally have higher latency, so this is a
// low-priority warning rather than a critical alert.
// ──────────────────────────────────────────────
resource latencyAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-cm-high-latency'
  location: 'global'
  properties: {
    description: 'Connection Monitor: average round-trip time exceeds 1000ms (informational — VPN paths have higher latency)'
    severity: 4
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      connectionMonitorId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighLatency'
          metricName: 'RoundTripTimeMs'
          metricNamespace: 'Microsoft.Network/networkWatchers/connectionMonitors'
          operator: 'GreaterThan'
          threshold: 1000
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
output checksFailedAlertId string = checksFailedAlert.id
output testResultAlertId string = testResultAlert.id
output latencyAlertId string = latencyAlert.id
