// On-prem alert rules (Stage 1): metric alerts on the on-prem Connection
// Monitor. Follows the existing '<prefix>-...-checks-failed' naming so the SRE
// Agent's response-plan title filter picks them up alongside the core lab.

@description('Resource naming prefix')
param prefix string

@description('Email address for alert notifications')
param alertEmail string

@description('On-prem Connection Monitor resource ID to monitor')
param connectionMonitorId string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-onprem-netops-ag'
  location: 'global'
  properties: {
    groupShortName: 'OnpNetOps'
    enabled: true
    emailReceivers: [
      {
        name: 'OnpNetOps-Email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Fires when probes to the on-prem server fail — i.e. the FRR router / LAN path
// is broken (data-plane detection).
resource checksFailedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-onprem-cm-checks-failed'
  location: 'global'
  properties: {
    description: 'On-prem Connection Monitor: more than 20% of probes to the on-prem server are failing (sustained over 5 min)'
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

resource testResultAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-onprem-cm-test-result-fail'
  location: 'global'
  properties: {
    description: 'On-prem Connection Monitor: one or more tests to the on-prem server report unreachable sustained over 5 min (TestResult=Fail)'
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

output actionGroupId string = actionGroup.id
output checksFailedAlertId string = checksFailedAlert.id
output testResultAlertId string = testResultAlert.id
