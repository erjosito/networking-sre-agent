<#
.SYNOPSIS
    Recording-oriented Azure Copilot Observability Agent demo.

.DESCRIPTION
    Demonstrates one of three opt-in application profiles:

      0. Start and verify the Observability API VM and lab Application Gateways,
         then confirm the baseline transaction succeeds.
      1. Record existing Azure Monitor issue IDs.
      2. Run DNS split-brain, dependency latency, or an application-only exception.
      3. Watch request/dependency/latency/exception signals become related alerts
         and, when the preview service is available, one Observability Agent issue.
      4. Revert any DNS mutation and verify the baseline user transaction.

    The Observability Agent investigates and recommends; it does not modify the
    environment. This script performs the explicit cleanup after the recording.

.PARAMETER Interactive
    Pause before fault injection and before cleanup for presenter-controlled pacing.

.PARAMETER PresenterMode
    Enable presenter hints, interactive pauses, and the event timeline.

.PARAMETER PresenterHints
    Print talking points and Azure Portal navigation guidance at each demo stage.

.PARAMETER Scenario
    dns-split-brain (default), dependency-latency, or application-exception.
    Only dns-split-brain mutates infrastructure.

.PARAMETER InvestigationStart
    Start the presenter investigation from an Azure Monitor alert ID or from the
    alert/Application Insights context already open in the Azure portal.

.PARAMETER SreHandoff
    Print an exact Observability-to-SRE handoff prompt before recovery.

.PARAMETER OpenPortal
    Open each suggested Azure resource in the default browser once. Use with
    PresenterMode or PresenterHints for a guided recording.

.PARAMETER Timeline
    Print and summarize timestamps for each observed event.

.PARAMETER PreflightOnly
    Restore and verify the baseline without injecting the fault.

.PARAMETER InfrastructureTimeoutMinutes
    Maximum time to wait for the Observability API VM and lab Application
    Gateways to reach a ready state during Phase 0 (default 15).

.PARAMETER NoRevert
    Leave the DNS fault active after the watch phase.

.PARAMETER StrictVerification
    Exit nonzero when delayed telemetry, alerts, or the preview agent-created issue
    are not observed. By default these are summarized as warnings so a presenter
    can still complete the demo after successful fault injection and recovery.

.PARAMETER TimeoutMinutes
    Maximum time to wait for the issue (default 30).

.EXAMPLE
    .\scripts\demo-observability.ps1 -PresenterMode -OpenPortal
    .\scripts\demo-observability.ps1 -Scenario dependency-latency -PresenterHints
    .\scripts\demo-observability.ps1 -Scenario application-exception -PresenterHints -InvestigationStart PortalContext
    .\scripts\demo-observability.ps1 -PresenterHints -Timeline
    .\scripts\demo-observability.ps1 -PreflightOnly
#>

[CmdletBinding()]
param(
    [ValidateSet("dns-split-brain", "dependency-latency", "application-exception")]
    [string]$Scenario = "dns-split-brain",
    [ValidateSet("AlertId", "PortalContext")]
    [string]$InvestigationStart = "AlertId",
    [switch]$SreHandoff,
    [switch]$Interactive,
    [switch]$PresenterMode,
    [switch]$PresenterHints,
    [switch]$OpenPortal,
    [switch]$Timeline,
    [switch]$PreflightOnly,
    [switch]$NoRevert,
    [switch]$StrictVerification,
    [int]$TimeoutMinutes = 30,
    [int]$BaselineTimeoutMinutes = 12,
    [int]$InfrastructureTimeoutMinutes = 15,
    [int]$PollSeconds = 20,
    [string]$Prefix = "netsre",
    [Alias("g")]
    [string]$ResourceGroup = "netsre-rg"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

if ($PresenterMode) {
    $Interactive = $true
    $PresenterHints = $true
    $Timeline = $true
}

function Write-Info { param([string]$Msg) Write-Host "[INFO]   $Msg" -ForegroundColor Cyan }
function Write-Ok { param([string]$Msg) Write-Host "[OK]     $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]   $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "[ERROR]  $Msg" -ForegroundColor Red }
function Write-Command { param([string]$Command) Write-Host "  $ $Command" -ForegroundColor DarkCyan }
function Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Magenta
    Write-Host "  $Title" -ForegroundColor Magenta
    Write-Host "=============================================================" -ForegroundColor Magenta
}
function Pause-Step {
    param([string]$Next)
    if ($Interactive) {
        Read-Host ">> Press Enter to $Next" | Out-Null
    }
}
function Get-PortalResourceUrl {
    param([string]$ResourceId)
    return "https://portal.azure.com/#@$($script:TenantId)/resource$ResourceId/overview"
}
function Show-PresenterCue {
    param(
        [string]$Title,
        [string[]]$TalkingPoints,
        [string]$PortalPath,
        [string]$ResourceId
    )
    if (-not $PresenterHints -and -not $OpenPortal) { return }

    if ($PresenterHints) {
        Write-Host ""
        Write-Host "[PRESENTER] $Title" -ForegroundColor Yellow
        foreach ($point in $TalkingPoints) {
            Write-Host "  - $point" -ForegroundColor Yellow
        }
        if ($PortalPath) {
            Write-Host "  Portal: $PortalPath" -ForegroundColor Cyan
        }
    }
    function Show-PromptCard {
        param([string]$Title, [string]$Prompt, [switch]$Force)
        if (-not $PresenterHints -and -not $Force) { return }
        Write-Host ""
        Write-Host "[PROMPT CARD - $Title]" -ForegroundColor Yellow
        Write-Host $Prompt -ForegroundColor White
    }

    if ($OpenPortal -and $ResourceId) {
        $url = Get-PortalResourceUrl -ResourceId $ResourceId
        if ($script:OpenedPortalUrls.Add($url)) {
            Write-Info "Opening suggested Portal resource..."
            Start-Process $url
        }
    }
}

$script:Events = [System.Collections.Generic.List[object]]::new()
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:OpenedPortalUrls = [System.Collections.Generic.HashSet[string]]::new()
$script:T0 = $null
function Record-Event {
    param([string]$Label, [string]$Detail = "", [datetime]$When = [datetime]::UtcNow)
    $event = [pscustomobject]@{
        Time = $When.ToUniversalTime()
        Label = $Label
        Detail = $Detail
    }
    $script:Events.Add($event)
    if ($Timeline) {
        $delta = "--:--"
        if ($script:T0) {
            $span = $event.Time - $script:T0
            $delta = "+{0:00}:{1:00}" -f [int]$span.TotalMinutes, $span.Seconds
        }
        Write-Host ("  [{0}Z T{1}] {2} {3}" -f $event.Time.ToString("HH:mm:ss"), $delta, $Label, $Detail) -ForegroundColor Magenta
    }
}
function Show-Timeline {
    if (-not $Timeline) { return }
    Banner "OBSERVABILITY TIMELINE"
    foreach ($event in ($script:Events | Sort-Object Time)) {
        $delta = "--:--"
        if ($script:T0) {
            $span = $event.Time - $script:T0
            $sign = if ($span.Ticks -lt 0) { "-" } else { "+" }
            $magnitude = [timespan]::FromTicks([math]::Abs($span.Ticks))
            $delta = "{0}{1:00}:{2:00}" -f $sign, [int]$magnitude.TotalMinutes, $magnitude.Seconds
        }
        Write-Host ("  {0}Z  T{1}  {2} {3}" -f $event.Time.ToString("HH:mm:ss"), $delta, $event.Label, $event.Detail)
    }
}

$ApiVmName = "$Prefix-observability-api"
$ApiRoleName = "$Prefix-network-transaction-api"
$AppInsightsName = "$Prefix-observability-api-ai"
$AmwName = "$Prefix-observability-amw"
$FaultScript = Join-Path $here "inject-fault.ps1"
$script:LawCustomerId = $null
$script:SubscriptionId = $null
$script:TenantId = $null
$script:ResourceIds = @{}
$script:ExistingIssueIds = @{}
$script:FaultInjected = $false
$script:LatestIssue = $null

$ScenarioConfig = @{
    "dns-split-brain" = @{
        Profile = "baseline"
        ExpectedStatus = 503
        Fault = "pe-dns-override"
        Alerts = @("$Prefix-api-transaction-failures", "$Prefix-api-dependency-failures")
        Layer = "spoke11 DNS / Private Endpoint invariant"
        Impact = "The API returns 503 because the dependency must stay on the private endpoint path; cross_hub_http stays healthy and optional on-prem should stay healthy."
        Expected = "private_endpoint_dns fails while cross_hub_http stays healthy; public DNS resolution is treated as a security/connectivity failure"
    }
    "dependency-latency" = @{
        Profile = "dependency-latency"
        ExpectedStatus = 200
        Fault = ""
        Alerts = @("$Prefix-api-dependency-latency")
        Layer = "cross_hub_http dependency path"
        Impact = "The user transaction remains successful but cross-hub dependency latency exceeds its alert threshold."
        Expected = "cross_hub_http is deliberately slow while every other dependency remains healthy"
    }
    "application-exception" = @{
        Profile = "application-exception"
        ExpectedStatus = 503
        Fault = ""
        Alerts = @("$Prefix-api-transaction-failures", "$Prefix-api-application-exceptions")
        Layer = "application code after dependency completion"
        Impact = "The user transaction fails in application code after every configured dependency succeeds."
        Expected = "all dependency checks are healthy and a structured application-exception response fails the request"
    }
}[$Scenario]

function Get-ApiCurlCommand {
    param([string]$ScenarioLabel, [string]$Profile)
    return "curl --silent --show-error --max-time 30 --header 'X-Lab-Scenario: $ScenarioLabel' --header 'X-Lab-Profile: $Profile' --write-out '\nHTTP_STATUS=%{http_code}\n' http://127.0.0.1:8080/api/transaction"
}

function Assert-Prerequisites {
    $account = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $account) { throw "Not logged in to Azure CLI." }
    Write-Ok "Subscription: $($account.name)"

    foreach ($resource in @(
        @{ Key = "ApiVm"; Type = "Microsoft.Compute/virtualMachines"; Name = $ApiVmName },
        @{ Key = "AppInsights"; Type = "Microsoft.Insights/components"; Name = $AppInsightsName },
        @{ Key = "MonitorWorkspace"; Type = "Microsoft.Monitor/accounts"; Name = $AmwName },
        @{ Key = "ObservabilityAgent"; Type = "Microsoft.Monitor/observabilityAgents"; Name = "$Prefix-observability-agent" }
    )) {
        $id = az resource show -g $ResourceGroup --resource-type $resource.Type -n $resource.Name --query id -o tsv 2>$null
        if (-not $id) { throw "Required resource not found: $($resource.Type)/$($resource.Name)" }
        $script:ResourceIds[$resource.Key] = $id
        Write-Ok "Found $($resource.Name)"
    }

    $spokeVnetId = az network vnet show -g $ResourceGroup -n "$Prefix-spoke11-vnet" --query id -o tsv 2>$null
    if (-not $spokeVnetId) { throw "Required VNet not found: $Prefix-spoke11-vnet" }
    $script:ResourceIds.SpokeVnet = $spokeVnetId
    Write-Ok "Found $Prefix-spoke11-vnet"

    $script:LawCustomerId = az monitor log-analytics workspace show -g $ResourceGroup -n "$Prefix-law" --query customerId -o tsv
    $script:SubscriptionId = $account.id
    $script:TenantId = $account.tenantId
}

function Ensure-ApiVmRunning {
    $deadline = (Get-Date).AddMinutes($InfrastructureTimeoutMinutes)
    $power = az vm get-instance-view -g $ResourceGroup -n $ApiVmName --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>$null
    if ($power -eq "VM running") {
        Write-Ok "$ApiVmName is already running."
        Record-Event "API VM ready" "$ApiVmName already running"
        return
    }
    if (-not $power) {
        throw "Could not read the power state for $ApiVmName."
    }

    Write-Info "Starting $ApiVmName from '$power'..."
    az vm start -g $ResourceGroup -n $ApiVmName --no-wait -o none
    do {
        Start-Sleep 15
        $power = az vm get-instance-view -g $ResourceGroup -n $ApiVmName --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>$null
        if ($power -eq "VM running") {
            Write-Ok "$ApiVmName is running."
            Record-Event "API VM ready" "$ApiVmName reached VM running"
            return
        }
        Write-Info "  waiting for $($ApiVmName) (state: $power)"
    } while ((Get-Date) -lt $deadline)

    throw "Timed out after $InfrastructureTimeoutMinutes minute(s) waiting for $ApiVmName to reach 'VM running' (last observed state: '$($power)')."
}

function Ensure-AppGatewaysRunning {
    $expectedNames = @("$Prefix-hub1-appgw", "$Prefix-hub2-appgw")
    Write-Info "Checking lab Application Gateways in $ResourceGroup..."
    $gateways = @(az network application-gateway list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json)

    $targets = @()
    foreach ($name in $expectedNames) {
        $gateway = $gateways | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $gateway) {
            throw "Required lab Application Gateway not found: $name. Phase 0 requires both $($expectedNames -join ', ') to be present."
        }

        $state = $gateway.operationalState
        if ($state -eq "Running") {
            Write-Ok "$name is already running."
            Record-Event "App Gateway ready" "$name already running"
            continue
        }

        Write-Info "Starting $name from '$state'..."
        az network application-gateway start -g $ResourceGroup -n $name --no-wait -o none
        $targets += [pscustomobject]@{ Name = $name; LastState = $state }
    }

    if ($targets.Count -eq 0) {
        Write-Ok "Both lab Application Gateways are already running."
        return
    }

    $deadline = (Get-Date).AddMinutes($InfrastructureTimeoutMinutes)
    $pending = @($targets)
    do {
        Start-Sleep 20
        $nextPending = @()
        foreach ($target in $pending) {
            $state = az network application-gateway show -g $ResourceGroup -n $target.Name --query "operationalState" -o tsv 2>$null
            if ($state -eq "Running") {
                Write-Ok "$($target.Name) is running."
                Record-Event "App Gateway ready" "$($target.Name) reached Running"
            } else {
                if (-not $state) { $state = "unknown" }
                Write-Info "  waiting for $($target.Name) (state: $state)"
                $nextPending += [pscustomobject]@{ Name = $target.Name; LastState = $state }
            }
        }
        $pending = @($nextPending)
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($pending.Count -gt 0) {
        $lastStates = ($pending | ForEach-Object { "$($_.Name)='$($_.LastState)'" }) -join ', '
        throw "Timed out after $InfrastructureTimeoutMinutes minute(s) waiting for lab Application Gateways to reach Running: $lastStates."
    }
}

function Invoke-ApiTransaction {
    param(
        [string]$ScenarioLabel = "baseline",
        [string]$Profile = "baseline"
    )
    $command = Get-ApiCurlCommand -ScenarioLabel $ScenarioLabel -Profile $Profile
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
    try {
        $raw = az vm run-command invoke -g $ResourceGroup -n $ApiVmName `
            --command-id RunShellScript `
            --scripts "echo $encoded | base64 -d | bash" `
            --query "value[0].message" -o tsv 2>$null
        $text = if ($raw -is [array]) { $raw -join "`n" } else { [string]$raw }
        $status = if ($text -match "HTTP_STATUS=(\d+)") { [int]$matches[1] } else { 0 }
        $jsonText = if ($text -match '(?s)\[stdout\]\s*(\{.*\})\s*HTTP_STATUS=') { $matches[1] } else { "" }
        $body = if ($jsonText) { $jsonText | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Status = $status; Body = $body; Raw = $text; Command = $command }
    } catch {
        return [pscustomobject]@{ Status = 0; Body = $null; Raw = $_.Exception.Message; Command = $command }
    }
}
function Show-TransactionResult {
    param($Result, [string]$Label)
    Write-Host ""
    Write-Host "[$Label] HTTP $($Result.Status)" -ForegroundColor DarkCyan
    if ($Result.Body) {
        $Result.Body | ConvertTo-Json -Depth 8 | Write-Host
    } else {
        Write-Host $Result.Raw
    }
    Write-Host ""
}

function Wait-ForTransactionState {
    param(
        [bool]$Success,
        [int]$TimeoutMinutes,
        [string]$ScenarioLabel = "baseline",
        [string]$Profile = "baseline"
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $result = Invoke-ApiTransaction -ScenarioLabel $ScenarioLabel -Profile $Profile
        $actualSuccess = $result.Status -eq 200 -and $result.Body -and $result.Body.success
        if ($actualSuccess -eq $Success) { return $result }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Test-ScenarioResult {
    param($Result)
    if (-not $Result.Body -or $Result.Status -ne $ScenarioConfig.ExpectedStatus) { return $false }
    $checks = @($Result.Body.checks)
    switch ($Scenario) {
        "dns-split-brain" {
            $dns = $checks | Where-Object name -eq "private_endpoint_dns" | Select-Object -First 1
            $crossHub = $checks | Where-Object name -eq "cross_hub_http" | Select-Object -First 1
            return $dns -and -not $dns.success -and $crossHub -and $crossHub.success
        }
        "dependency-latency" {
            $crossHub = $checks | Where-Object name -eq "cross_hub_http" | Select-Object -First 1
            $otherFailures = @($checks | Where-Object { $_.name -ne "cross_hub_http" -and -not $_.success })
            return $Result.Body.success -and $crossHub -and $crossHub.success -and
                $crossHub.detail -like "injected * latency;*" -and $otherFailures.Count -eq 0
        }
        "application-exception" {
            $dependencyFailures = @($checks | Where-Object { -not $_.success })
            $failureProperty = $Result.Body.PSObject.Properties["failure"]
            return -not $Result.Body.success -and $dependencyFailures.Count -eq 0 -and
                $failureProperty -and $failureProperty.Value.type -eq "application-exception"
        }
    }
    return $false
}

function Wait-ForScenarioResult {
    param([int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $result = Invoke-ApiTransaction -ScenarioLabel $Scenario -Profile $ScenarioConfig.Profile
        if (Test-ScenarioResult -Result $result) { return $result }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-ScenarioPulse {
    if ($Scenario -ne "dns-split-brain") {
        Invoke-ApiTransaction -ScenarioLabel $Scenario -Profile $ScenarioConfig.Profile | Out-Null
    }
}

function Get-AppTelemetry {
    param([datetime]$SinceUtc)
    $since = $SinceUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $query = "union (AppRequests | project TimeGenerated, AppRoleName, Success, ItemType='request', DurationMs=real(0)), " +
        "(AppDependencies | project TimeGenerated, AppRoleName, Success, ItemType='dependency', DurationMs), " +
        "(AppExceptions | project TimeGenerated, AppRoleName, Success=false, ItemType='exception', DurationMs=real(0)) | " +
        "where TimeGenerated >= datetime($since) and AppRoleName == '$ApiRoleName' | " +
        "summarize RequestCount=countif(ItemType == 'request'), " +
        "FailedRequests=countif(ItemType == 'request' and Success == false), " +
        "DependencyCount=countif(ItemType == 'dependency'), " +
        "FailedDependencies=countif(ItemType == 'dependency' and Success == false), " +
        "SlowDependencies=countif(ItemType == 'dependency' and DurationMs >= 2000), " +
        "ExceptionCount=countif(ItemType == 'exception'), " +
        "LastRequest=maxif(TimeGenerated, ItemType == 'request'), " +
        "LastDependency=maxif(TimeGenerated, ItemType == 'dependency')"
    try {
        $rows = az monitor log-analytics query --workspace $script:LawCustomerId --analytics-query $query -o json 2>$null | ConvertFrom-Json
        return @($rows) | Select-Object -First 1
    } catch {
        return $null
    }
}

function Test-TelemetryObserved {
    param($Telemetry)
    if (-not $Telemetry) { return $false }
    switch ($Scenario) {
        "dns-split-brain" {
            return [int]$Telemetry.FailedRequests -gt 0 -and [int]$Telemetry.FailedDependencies -gt 0
        }
        "dependency-latency" {
            return [int]$Telemetry.SlowDependencies -gt 0
        }
        "application-exception" {
            return [int]$Telemetry.FailedRequests -gt 0 -and [int]$Telemetry.ExceptionCount -gt 0
        }
    }
    return $false
}

function Get-FiredAlert {
    param([string]$Name, [datetime]$SinceUtc)
    $url = "https://management.azure.com/subscriptions/$script:SubscriptionId/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview"
    try {
        $alerts = (az rest --method get --url $url -o json 2>$null | ConvertFrom-Json).value
        return $alerts |
            Where-Object {
                $_.name -eq $Name -or
                $_.properties.essentials.alertRule -eq $Name -or
                $_.properties.essentials.alertRule -like "*/$Name"
            } |
            Where-Object { $_.properties.essentials.monitorCondition -eq "Fired" } |
            Where-Object { ([datetime]$_.properties.essentials.startDateTime).ToUniversalTime() -ge $SinceUtc.AddMinutes(-2) } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-Issues {
    $amwId = az resource show -g $ResourceGroup --resource-type "Microsoft.Monitor/accounts" -n $AmwName --query id -o tsv 2>$null
    if (-not $amwId) { return @() }
    $url = "https://management.azure.com${amwId}/issues?api-version=2025-10-03"
    try {
        return @((az rest --method get --url $url -o json 2>$null | ConvertFrom-Json).value)
    } catch {
        return @()
    }
}

function Record-ExistingIssues {
    foreach ($issue in (Get-Issues)) {
        $script:ExistingIssueIds[$issue.id] = $true
    }
    Write-Info "Ignoring $($script:ExistingIssueIds.Count) pre-existing issue(s)."
}

function Get-NewAgentIssue {
    param([datetime]$SinceUtc)
    return Get-Issues |
        Where-Object { -not $script:ExistingIssueIds.ContainsKey($_.id) } |
        Where-Object { $_.properties.impactTime -and ([datetime]$_.properties.impactTime).ToUniversalTime() -ge $SinceUtc.AddMinutes(-2) } |
        Where-Object {
            ($_.properties.title -and $_.properties.title.StartsWith("[$AppInsightsName]")) -or
            $_.properties.background.text -like "*Observability Agent created this issue*"
        } |
        Sort-Object { [datetime]$_.properties.impactTime } |
        Select-Object -First 1
}

function Show-Issue {
    param($Issue)
    Banner "OBSERVABILITY AGENT ISSUE"
    Write-Host "Title      : $($Issue.properties.title)" -ForegroundColor Green
    Write-Host "Severity   : $($Issue.properties.severity)"
    Write-Host "Status     : $($Issue.properties.status)"
    Write-Host "Impact time: $($Issue.properties.impactTime)"
    if ($Issue.properties.background.text) {
        Write-Host ""
        Write-Host $Issue.properties.background.text -ForegroundColor Cyan
    }
    Write-Host ""
    Show-PresenterCue -Title "Open the correlated issue" -TalkingPoints @(
        "Show that the issue groups application symptoms instead of presenting isolated alerts."
        "Read the Background explanation and point out the affected and healthy dependencies."
        "Open the investigation to review evidence, hypotheses, and recommendations."
    ) -PortalPath "Azure Monitor -> Issues -> $AmwName -> $($Issue.properties.title)" `
        -ResourceId $script:ResourceIds.MonitorWorkspace
}

function Show-InvestigationStart {
    param([object[]]$Alerts)
    if (-not $PresenterHints) { return }
    if ($InvestigationStart -eq "AlertId") {
        $firstAlert = $Alerts | Where-Object { $_ } | Select-Object -First 1
        $alertId = if ($firstAlert) { $firstAlert.id } else { "<paste-alert-id>" }
        Show-PromptCard -Title "INVESTIGATE FROM ALERT ID" -Prompt "Investigate Azure Monitor alert ID '$alertId'. Correlate requests, dependencies, exceptions, traces, logs, changes, and related alerts only from the same operation or incident time window. Identify user impact, affected and healthy dependencies, blast radius, likely cause, confidence, and the evidence supporting each conclusion."
    } else {
        Show-PromptCard -Title "INVESTIGATE FROM PORTAL CONTEXT" -Prompt "Using the Azure Monitor alert and Application Insights context currently open in the portal, investigate this incident. Correlate only signals from the same operation or incident time window. Identify user impact, affected and healthy dependencies, blast radius, likely cause, confidence, and the evidence supporting each conclusion."
    }
}

function Show-InvestigationPromptCards {
    Show-PromptCard -Title "FINDINGS" -Prompt "Summarize the findings in five bullets: user impact, failed signal, healthy signals, localized layer, and confidence. Include timestamps and operation or correlation IDs where available."
    Show-PromptCard -Title "EVIDENCE" -Prompt "Build an evidence table with signal, timestamp, resource or dependency, observed value, and what it proves. Separate direct evidence from inference."
    Show-PromptCard -Title "HYPOTHESES RULED OUT" -Prompt "List the plausible hypotheses you ruled out, the evidence that rules each one out, and any hypothesis that remains unresolved. Do not claim a cause without supporting telemetry."
    Show-PromptCard -Title "REMEDIATION" -Prompt "Recommend the safest remediation for the localized layer. State prerequisites, blast-radius risk, rollback steps, and the exact user transaction that must be verified afterward. Do not apply changes."
    Show-PromptCard -Title "RECURRENCE" -Prompt "Assess whether this happened before. Search the relevant telemetry for comparable request, dependency, latency, exception, and alert patterns, and distinguish genuine recurrence from this lab run."
    Show-PromptCard -Title "RELATED ALERTS" -Prompt "Find alerts related to this incident by resource, operation, and time window. Explain which belong in one Azure Monitor issue and explicitly exclude alerts from unrelated profile runs or deployment prefixes."
}

function Show-SreHandoff {
    if (-not $SreHandoff) { return }
    $recoveryCommand = Get-ApiCurlCommand -ScenarioLabel "recovery" -Profile "baseline"
    Show-PromptCard -Title "OBSERVABILITY TO SRE HANDOFF" -Prompt "Investigate and safely remediate the incident affecting '$ApiRoleName'. Observability evidence: $($ScenarioConfig.Impact) Localized layer: $($ScenarioConfig.Layer). Expected signal boundary: $($ScenarioConfig.Expected). Correlate only evidence from $($script:T0.ToString('o')) onward and preserve the healthy dependencies. If remediation is unsafe, unavailable, or fails, return a support-escalation package with symptoms, business impact, evidence, diagnostics already run, exact commands, and remaining hypotheses. After remediation, verify the user transaction with: $recoveryCommand" -Force
}

function Show-DnsSplitBrainBriefing {
    param(
        [string]$SpokeDns = "10.1.1.200",
        [string]$PrivateEndpointIp = "10.1.4.4"
    )

    Write-Host ""
    Write-Host "[DNS SPLIT-BRAIN BRIEFING]" -ForegroundColor Yellow
    Write-Info "This is split-brain DNS, not a total outage: the same storage static-website FQDN resolves privately through the intended path, but to a public address from spoke11 when Azure-provided DNS is used."
    Write-Info "Normal chain: API VM -> spoke11 custom DNS $SpokeDns -> Hub1 NVA dnsmasq -> Azure DNS in the hub/private-zone-linked context -> privatelink.web.core.windows.net -> PE $PrivateEndpointIp."
    Write-Info "Fault: pe-dns-override resets spoke11 VNet DNS to Azure-provided DNS; because the private DNS zone is linked only to hub VNets, the spoke gets the public answer instead of the private one."
    Write-Info "The fault script restarts the relevant workloads/VMs so DHCP-provided DNS settings renew; that is why the change is not instant."
    Write-Info "Blast radius stays bounded: cross_hub_http remains healthy, optional on-prem should stay healthy if configured, and the API returns 503 because the transaction treats public resolution as a security/connectivity failure."
    Write-Info "Recovery proof: restore $SpokeDns, renew settings or restart, and the same unmodified transaction returns 200 with private resolution again."

    Show-PresenterCue -Title "Explain the controlled DNS change" -TalkingPoints @(
        "DNS split-brain here means the same storage static-website FQDN resolves to the private endpoint IP through the intended resolver chain, but to a public address when spoke11 uses Azure-provided DNS."
        "The private DNS zone is linked only to the hub VNets, so pe-dns-override removes the spoke from the intended resolution path without creating a total DNS outage."
        "The workload restart is intentional: DHCP-provided DNS settings have to be renewed before the split-brain becomes visible in the transaction."
        "Before and after, show the DNS server setting, the resolved address/detail, the failed private_endpoint_dns check, the healthy cross_hub_http check, and the HTTP 503."
        "Observability Agent should infer one bounded application issue and the likely layer; the SRE Agent should restore the custom DNS path and verify private resolution returns."
    ) -PortalPath "Virtual networks -> $Prefix-spoke11-vnet -> Settings -> DNS servers" `
        -ResourceId $script:ResourceIds.SpokeVnet
}

function Show-OnCallEpilogue {
    if (-not $PresenterHints) { return }
    Banner "ON-CALL EPILOGUE"
    Write-Host "  SHIFT START : Review active issues, recent changes, and the healthy baseline before acting."
    Write-Host "  INVESTIGATE : Correlate only same-window evidence; separate affected and healthy dependencies."
    Write-Host "  DOCUMENT    : Capture findings, evidence, ruled-out hypotheses, remediation, and recurrence."
    Write-Host "  VERIFY      : Re-run the baseline user transaction and confirm alerts begin to resolve."
    Write-Host "  HANDOFF     : Transfer the localized layer, evidence, exact prompt, owner, and remaining risk."
}

function Restore-Baseline {
    Banner "PHASE 0 - PREPARE BASELINE"
    Write-Info "Phase 0 starts and waits for the Observability API VM and both lab Application Gateways before baseline validation."
    Ensure-ApiVmRunning
    Ensure-AppGatewaysRunning

    $nvaDns = az network lb frontend-ip show -g $ResourceGroup -n nva-frontend `
        --lb-name "$Prefix-hub1-nva-lb" --query privateIPAddress -o tsv
    $currentDns = az network vnet show -g $ResourceGroup -n "$Prefix-spoke11-vnet" `
        --query "dhcpOptions.dnsServers[0]" -o tsv
    if ($currentDns -ne $nvaDns) {
        if ($Scenario -ne "dns-split-brain") {
            throw "Spoke11 DNS is not at baseline. The '$Scenario' profile never mutates infrastructure; restore pe-dns-override before running it."
        }
        Write-Info "Restoring spoke11 DNS before the DNS scenario..."
        & $FaultScript -Scenario pe-dns-override -ResourceGroup $ResourceGroup -Prefix $Prefix -Revert
    }

    $baselineCommand = Get-ApiCurlCommand -ScenarioLabel "baseline" -Profile "baseline"
    Write-Info "Running the end-to-end transaction inside ${ApiVmName}:"
    Write-Command $baselineCommand
    Write-Info "The script transports this command with: az vm run-command invoke -g $ResourceGroup -n $ApiVmName ..."
    $baseline = Wait-ForTransactionState -Success $true -TimeoutMinutes $BaselineTimeoutMinutes `
        -ScenarioLabel "baseline" -Profile "baseline"
    if (-not $baseline) { throw "The telemetry API did not reach a healthy baseline." }
    Show-TransactionResult -Result $baseline -Label "BASELINE RESPONSE"
    $checks = $baseline.Body.checks | ForEach-Object { "$($_.name)=OK" }
    Write-Ok "Baseline transaction succeeded: $($checks -join ', ')"
    Record-Event "Baseline transaction healthy" ($checks -join ", ")
    Show-PresenterCue -Title "Establish the healthy application baseline" -TalkingPoints @(
        "The synthetic API represents a user transaction, not a network-device health probe."
        "Private Endpoint DNS and cross-hub HTTP are both healthy before the change."
        "In Application Map, identify the API and its downstream dependencies."
    ) -PortalPath "Application Insights -> Application Map; then Investigate -> Failures" `
        -ResourceId $script:ResourceIds.AppInsights
}

Assert-Prerequisites
Restore-Baseline
Record-ExistingIssues
if ($PreflightOnly) {
    Write-Ok "Preflight complete. No fault injected."
    Show-Timeline
    exit 0
}

Pause-Step "run scenario '$Scenario'"
Banner "PHASE 1 - RUN $($Scenario.ToUpperInvariant())"
if ($Scenario -eq "dns-split-brain") {
    Show-DnsSplitBrainBriefing
} elseif ($Scenario -eq "dependency-latency") {
    Show-PresenterCue -Title "Explain the dependency-specific latency profile" -TalkingPoints @(
        "The request header selects an application profile; no Azure resource is changed."
        "Only cross_hub_http receives the configured delay."
        "The remaining dependencies stay healthy, bounding blast radius to one path."
    ) -PortalPath "Application Insights -> Investigate -> Performance -> Dependencies" `
        -ResourceId $script:ResourceIds.AppInsights
} else {
    Show-PresenterCue -Title "Explain the application-only exception profile" -TalkingPoints @(
        "The request header selects an application profile; no Azure resource is changed."
        "Every dependency check completes successfully before the application records an exception."
        "This contrasts an application failure with the DNS/network failure without changing infrastructure."
    ) -PortalPath "Application Insights -> Investigate -> Failures -> Exceptions" `
        -ResourceId $script:ResourceIds.AppInsights
}

$script:T0 = [datetime]::UtcNow
if ($ScenarioConfig.Fault) {
    & $FaultScript -Scenario $ScenarioConfig.Fault -ResourceGroup $ResourceGroup -Prefix $Prefix
    $script:FaultInjected = $true
    Record-Event "Fault injected" $ScenarioConfig.Fault
} else {
    Record-Event "Application profile selected" "$($ScenarioConfig.Profile); no infrastructure mutation"
}

try {
    Banner "PHASE 2 - WATCH THE SIGNAL CASCADE"
    $scenarioCommand = Get-ApiCurlCommand -ScenarioLabel $Scenario -Profile $ScenarioConfig.Profile
    Write-Info "Running the exact scenario transaction inside ${ApiVmName}:"
    Write-Command $scenarioCommand
    Write-Info "Waiting for the expected profile result while unaffected checks remain visible..."
    $scenarioResult = Wait-ForScenarioResult -TimeoutMinutes 8
    if ($scenarioResult) {
        Show-TransactionResult -Result $scenarioResult -Label "SCENARIO RESPONSE"
        $failedChecks = @($scenarioResult.Body.checks | Where-Object { -not $_.success } | ForEach-Object { $_.name })
        $healthyChecks = @($scenarioResult.Body.checks | Where-Object success | ForEach-Object { $_.name })
        Write-Ok "Expected scenario behavior observed."
        Write-Host "  Failed : $($failedChecks -join ', ')" -ForegroundColor Red
        Write-Host "  Healthy: $($healthyChecks -join ', ')" -ForegroundColor Green
        $failureProperty = $scenarioResult.Body.PSObject.Properties["failure"]
        if ($failureProperty -and $failureProperty.Value) {
            Write-Host "  Failure: $($failureProperty.Value.type) at $($failureProperty.Value.component)" -ForegroundColor Red
        }
        Record-Event "Scenario transaction observed" $ScenarioConfig.Expected
        Show-PresenterCue -Title "Show the bounded application impact" -TalkingPoints @(
            $ScenarioConfig.Impact
            "Expected boundary: $($ScenarioConfig.Expected)."
            "Use failed and healthy checks together to localize the layer before proposing a cause."
        ) -PortalPath "Application Insights -> Investigate -> Failures; select a GET /api/transaction from this time window" `
            -ResourceId $script:ResourceIds.AppInsights
    } else {
        Write-Warn "The expected '$Scenario' result was not observed within 8 minutes."
        $script:Failures.Add("Expected scenario behavior was not observed.")
    }

    Write-Info "Waiting for scenario telemetry in Application Insights..."
    $telemetryDeadline = (Get-Date).AddMinutes(10)
    $telemetry = $null
    do {
        $telemetry = Get-AppTelemetry -SinceUtc $script:T0
        if (Test-TelemetryObserved -Telemetry $telemetry) { break }
        Invoke-ScenarioPulse
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep $PollSeconds
    } while ((Get-Date) -lt $telemetryDeadline)
    Write-Host ""
    if (Test-TelemetryObserved -Telemetry $telemetry) {
        Write-Ok "Application Insights: failed requests=$($telemetry.FailedRequests), failed dependencies=$($telemetry.FailedDependencies), slow dependencies=$($telemetry.SlowDependencies), exceptions=$($telemetry.ExceptionCount)."
        Record-Event "Application telemetry ingested" "failedRequests=$($telemetry.FailedRequests), failedDependencies=$($telemetry.FailedDependencies), slowDependencies=$($telemetry.SlowDependencies), exceptions=$($telemetry.ExceptionCount)"
        Show-PresenterCue -Title "Walk the distributed trace" -TalkingPoints @(
            "Open the request and follow its end-to-end transaction details."
            "Correlate request, dependency, latency, and exception signals from this operation and time window."
            "Use successful dependencies as evidence; do not pull unrelated profile runs into the conclusion."
        ) -PortalPath "Application Insights -> Investigate -> Transaction search -> End-to-end transaction details" `
            -ResourceId $script:ResourceIds.AppInsights
    } else {
        Write-Warn "Expected telemetry was not queryable within 10 minutes."
        $script:Warnings.Add("Expected request/dependency/latency/exception telemetry was not queryable.")
    }

    Write-Info "Waiting for the expected application alert rule(s) to fire..."
    $alertDeadline = (Get-Date).AddMinutes(12)
    $alertsByName = @{}
    do {
        foreach ($alertName in $ScenarioConfig.Alerts) {
            if (-not $alertsByName.ContainsKey($alertName)) {
                $alert = Get-FiredAlert -Name $alertName -SinceUtc $script:T0
                if ($alert) { $alertsByName[$alertName] = $alert }
            }
        }
        if ($alertsByName.Count -eq $ScenarioConfig.Alerts.Count) { break }
        Invoke-ScenarioPulse
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep $PollSeconds
    } while ((Get-Date) -lt $alertDeadline)
    Write-Host ""
    foreach ($alertName in $ScenarioConfig.Alerts) {
        if ($alertsByName.ContainsKey($alertName)) {
            Write-Ok "Alert fired: $alertName"
            Record-Event "Alert fired" $alertName
        } else {
            Write-Warn "Alert not observed: $alertName"
            $script:Warnings.Add("Alert was not observed: $alertName.")
        }
    }

    Show-PresenterCue -Title "Show symptom-to-alert escalation" -TalkingPoints @(
        "Filter to the $ResourceGroup resource group and the last 30 minutes."
        "One profile can produce multiple alert instances that describe different views of the same fault."
        "Correlate alerts into one Azure Monitor issue only when resource, operation, and time-window evidence agrees."
        "Keep alerts from unrelated profile runs or prefixes out of this issue."
    ) -PortalPath "Azure Monitor -> Alerts -> Alert instances; filter by $ResourceGroup" `
        -ResourceId $script:ResourceIds.AppInsights
    Show-InvestigationStart -Alerts @($alertsByName.Values)
    Show-InvestigationPromptCards

    $deadline = $script:T0.AddMinutes($TimeoutMinutes)
    Show-PresenterCue -Title "Watch autonomous issue correlation" -TalkingPoints @(
        "Refresh Issues while the related alerts are active."
        "An agent-created issue is prefixed with [$AppInsightsName]."
        "The Background should explain why same-window signals belong together; investigation follows automatically."
    ) -PortalPath "Azure Monitor -> Issues -> workspace $AmwName" `
        -ResourceId $script:ResourceIds.MonitorWorkspace
    Write-Info "Waiting for the Observability Agent to correlate the alerts and create an issue..."
    $issue = $null
    do {
        $issue = Get-NewAgentIssue -SinceUtc $script:T0
        if ($issue) { break }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    Write-Host ""
    if ($issue) {
        Write-Ok "One new Observability Agent issue created."
        Record-Event "Observability Agent issue created" $issue.properties.title
        $script:LatestIssue = $issue
        Show-Issue $issue
    } else {
        Write-Warn "No new issue was visible before the $TimeoutMinutes-minute timeout."
        Write-Info "Check Azure portal -> Monitor -> Issues -> $AmwName."
        $script:Warnings.Add("The Observability Agent did not create an Azure Monitor issue.")
    }
    Show-SreHandoff
} finally {
    if (-not $NoRevert) {
        Pause-Step "remediate or reset the profile and verify the user transaction"
        Banner "PHASE 3 - RECOVER AND VERIFY"
        if ($script:FaultInjected) {
            & $FaultScript -Scenario $ScenarioConfig.Fault -ResourceGroup $ResourceGroup -Prefix $Prefix -Revert
            Record-Event "Fault reverted" $ScenarioConfig.Fault
        } else {
            Record-Event "Profile reset" "subsequent request uses baseline"
        }
        Write-Info "Waiting for the baseline user transaction to recover..."
        Write-Command (Get-ApiCurlCommand -ScenarioLabel "recovery" -Profile "baseline")
        $recovered = Wait-ForTransactionState -Success $true -TimeoutMinutes $BaselineTimeoutMinutes `
            -ScenarioLabel "recovery" -Profile "baseline"
        if ($recovered) {
            Show-TransactionResult -Result $recovered -Label "RECOVERY RESPONSE"
            Write-Ok "Baseline user transaction verified."
            Record-Event "User transaction verified"
            $recoveryTalkingPoints = @(
                "The same baseline transaction is healthy again."
                "All configured dependency checks succeed after remediation or profile reset."
                "The Observability Agent supplied correlation and localization; remediation ownership is explicit."
            )
            if ($Scenario -eq "dns-split-brain") {
                $recoveryTalkingPoints = @(
                    "The same baseline transaction is healthy again."
                    "Spoke11 is back on 10.1.1.200; private resolution returns and the same unmodified request now gets HTTP 200."
                    "All configured dependency checks succeed after remediation or profile reset."
                    "The Observability Agent supplied correlation and localization; remediation ownership is explicit."
                )
            }
            Show-PresenterCue -Title "Close with recovery evidence" -TalkingPoints $recoveryTalkingPoints -PortalPath "Application Insights -> Application Map and Failures; set time range to Last 30 minutes" `
                -ResourceId $script:ResourceIds.AppInsights
        } else {
            Write-Warn "The application did not recover before the baseline timeout."
            $script:Failures.Add("The application did not recover after fault reversion or profile reset.")
        }
    } elseif ($script:FaultInjected) {
        Write-Warn "Fault left active because -NoRevert was specified."
    } else {
        Write-Warn "Recovery transaction skipped because -NoRevert was specified; no infrastructure was mutated."
    }
}

Show-Timeline
Show-OnCallEpilogue
if ($script:Failures.Count -gt 0) {
    throw "Demo verification failed: $($script:Failures -join ' ')"
}
if ($script:Warnings.Count -gt 0) {
    Banner "DEMO COMPLETED WITH WARNINGS"
    foreach ($warning in $script:Warnings) {
        Write-Warn $warning
    }
    if ($StrictVerification) {
        throw "Strict verification failed: $($script:Warnings -join ' ')"
    }
    Write-Info "Fault injection and recovery succeeded. Delayed preview signals did not block cleanup."
}
Write-Ok "Observability Agent demo complete."
