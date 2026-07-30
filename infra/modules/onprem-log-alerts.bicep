// On-prem telemetry alerts (Part B): fires the SRE Agent on critical signals from
// the on-prem telemetry pipelines that Connection Monitor cannot see — FRR/device
// syslog, RADIUS AAA audit failures, telemetry-collector loss, and SNMP device
// reboots. Log-search rules are scoped to the Log Analytics workspace; the SNMP
// rule is a metric alert on the collector VM's custom metric namespace.
//
// These complement the Connection Monitor metric alerts (alerts.bicep): CM detects
// data-path reachability, these detect control-plane / audit / device-health events.

@description('Resource naming prefix')
param prefix string

@description('Azure region for the alert rules')
param location string

@description('Email address for alert notifications')
param alertEmail string

@description('Log Analytics workspace resource ID (scope for log-search alerts)')
param logAnalyticsWorkspaceId string

@description('Telemetry collector VM resource ID (scope for the SNMP metric alert)')
param collectorVmId string

@description('Computer name of the telemetry collector in Heartbeat (AMA)')
param collectorComputerName string = 'onprem-collector'

// ──────────────────────────────────────────────
// Action Group
// ──────────────────────────────────────────────
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-onprem-ag'
  location: 'global'
  properties: {
    groupShortName: 'OnPrem'
    enabled: true
    emailReceivers: [
      {
        name: 'OnPrem-Email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Alert 1 (log): critical syslog from on-prem devices
// FRR logs to the 'daemon' facility; interface/BGP/adjacency failures surface at
// error severity or worse. Any error+ message over 5 min is worth surfacing.
// ──────────────────────────────────────────────
resource syslogCriticalAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-onprem-syslog-critical'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-onprem-syslog-critical'
    description: 'On-prem device syslog reported an error-or-worse event (FRR/interface/BGP/kernel). Fires per device (HostName) and subsystem (ProcessName: bgpd/ospfd/zebra/kernel).'
    severity: 2
    enabled: true
    scopes: [ logAnalyticsWorkspaceId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'Syslog\n| where SeverityLevel in ("error", "critical", "alert", "emergency")'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          // Split the alert by device (HostName) and subsystem (ProcessName, e.g.
          // bgpd / ospfd / zebra / kernel) so the fired alert names WHICH device and
          // WHICH daemon logged the error. These are low-cardinality. The exact
          // message body is retrieved by the response plan's processing guide
          // (Step 1) rather than carried as a high-cardinality dimension.
          dimensions: [
            {
              name: 'HostName'
              operator: 'Include'
              values: [ '*' ]
            }
            {
              name: 'ProcessName'
              operator: 'Include'
              values: [ '*' ]
            }
            {
              name: 'SeverityLevel'
              operator: 'Include'
              values: [ '*' ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

// ──────────────────────────────────────────────
// Alert 2 (log): RADIUS AAA authentication failures
// Repeated Login-incorrect events on network devices = misconfig or brute force.
// ──────────────────────────────────────────────
resource aaaFailuresAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-onprem-aaa-auth-failures'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-onprem-aaa-auth-failures'
    description: 'Three or more RADIUS AAA authentication failures on on-prem network devices within 15 minutes.'
    severity: 2
    enabled: true
    scopes: [ logAnalyticsWorkspaceId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'OnPremAAA_CL\n| where Result == "Failure"'
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 3
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

// ──────────────────────────────────────────────
// Alert 3 (log): telemetry collector heartbeat missing
// The collector runs the AMA and terminates syslog/SNMP/AAA ingestion. If it stops
// sending heartbeats the entire on-prem telemetry pipeline is blind — critical.
// ──────────────────────────────────────────────
resource collectorDownAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-onprem-collector-heartbeat-missing'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: '${prefix}-onprem-collector-heartbeat-missing'
    description: 'No heartbeat from the on-prem telemetry collector in the last 10 minutes — telemetry ingestion is down.'
    severity: 1
    enabled: true
    scopes: [ logAnalyticsWorkspaceId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    criteria: {
      allOf: [
        {
          query: 'Heartbeat\n| where Computer == "${collectorComputerName}"'
          timeAggregation: 'Count'
          operator: 'LessThanOrEqual'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

// ──────────────────────────────────────────────
// Alert 4 (metric): SNMP device reboot (sysUpTime reset)
// Telegraf publishes SNMP sysUpTime (TimeTicks, hundredths of a second) to the
// custom metric namespace 'onprem/snmp' on the collector VM resource. A low minimum
// over the window means a monitored device restarted recently.
// ──────────────────────────────────────────────
resource snmpUptimeResetAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-onprem-snmp-uptime-reset'
  location: 'global'
  properties: {
    description: 'SNMP sysUpTime dropped below 5 minutes — a monitored on-prem device rebooted.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [ collectorVmId ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'SysUpTimeReset'
          metricName: 'sysUpTime'
          metricNamespace: 'onprem/snmp'
          operator: 'LessThan'
          threshold: 30000
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
// Outputs
// ──────────────────────────────────────────────
output actionGroupId string = actionGroup.id
output syslogCriticalAlertId string = syslogCriticalAlert.id
output aaaFailuresAlertId string = aaaFailuresAlert.id
output collectorDownAlertId string = collectorDownAlert.id
output snmpUptimeResetAlertId string = snmpUptimeResetAlert.id
