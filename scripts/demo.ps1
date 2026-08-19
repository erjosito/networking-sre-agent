<#
.SYNOPSIS
    One-command SRE Agent live demo: pre-flight → inject → watch → revert.

.DESCRIPTION
    Runs an end-to-end, on-camera demonstration of the Azure SRE Agent detecting,
    investigating and (in Autonomous mode) remediating a networking fault.

    Phases:
      0. Pre-flight (ALWAYS runs, auto-fixes)  — make the lab clean before the fault:
           • verify az login
           • start EVERY lab VM that is deallocated (so all Connection Monitors can
             go green — a down source/destination VM fails its CM and fires alerts
             that have nothing to do with the demo)
           • (clab) rebuild the containerlab fabric + host-probe wiring if broken
           • delete any existing SRE Agent incidents (so the new alert opens a FRESH
             incident instead of merging into a stale one)
           • wait until the scenario's Connection Monitors report GREEN (baseline)
      1. Inject a fault      — one Azure fault or one containerlab fabric fault.
      2. Watch the agent      — live-tail the incident it opens: its plan, the
                                 diagnostics it runs, and its root-cause verdict.
      3. Revert the fault     — restore a clean environment for the next take.

    Two ready-made scenarios:
      -Scenario azure  → 'udr-wrong-nexthop'      (spoke11 default route next-hop set to an
                          unreachable IP — the classic "next-hop off by one" black-hole; every
                          resource still looks healthy, but spoke11 Connection Monitors fail)
      -Scenario clab   → 'clab-ospf-area-mismatch' (OSPF area mismatch on the on-prem fabric —
                          adjacency drops, peer loopback withdrawn, BGP-over-loopback tears down,
                          LAN withdrawn; the clab Connection Monitor fails and bgpd logs to syslog)

    Override the exact fault with -FaultName (any scripts/inject-fault.ps1 scenario).

.PARAMETER Scenario
    'azure' or 'clab' — selects a curated fault (see above).

.PARAMETER FaultName
    Use a specific inject-fault.ps1 scenario name instead of the curated one.

.PARAMETER Interactive
    Pause for a keypress before each phase (recommended for live recording so you
    control pacing / narration). Omit for an unattended rehearsal.

.PARAMETER Timeline
    Timestamp every action AND actively watch for each cascade event to occur —
    baseline CMs green, fault injected (T0), Connection Monitor goes red, syslog
    (BGP/OSPF) arrives, the metric alert fires, the SRE Agent opens the incident,
    and (after remediation) recovery. Prints a live ⏱ marker at each event and a
    timeline summary table at the end. Great for rehearsals to learn the real
    latencies between links in the chain.

.PARAMETER ContextualTroubleshooting
    Before fault injection, print an optional Azure portal resource-picker step and
    an exact contextual troubleshooting prompt for the curated scenario.

.PARAMETER SupportEscalation
    Print a case-ready support escalation package before cleanup. Use when proposed
    remediation is unsafe, unavailable, withheld, or unsuccessful.

.PARAMETER TimeoutMinutes
    How long to watch the investigation (default 30).

.PARAMETER BaselineTimeoutMinutes
    How long pre-flight waits for the Connection Monitors to go green after starting
    VMs (default 15). A just-started VM needs a few minutes before its Network Watcher
    agent reports again.

.PARAMETER PreflightOnly
    Run pre-flight (make the lab clean) and then stop — no inject/watch/revert. Use to
    warm and verify the lab ahead of a recording.

.PARAMETER NoWatch     Inject only; do not stream the investigation.
.PARAMETER NoRevert    Leave the fault injected at the end (you revert manually).
.PARAMETER Prefix / -ResourceGroup   Lab naming (defaults: netsre / netsre-rg).

.EXAMPLE
    .\demo.ps1 -Scenario clab -Interactive
    .\demo.ps1 -Scenario clab -Timeline          # rehearsal: learn the cascade timings
    .\demo.ps1 -Scenario azure -TimeoutMinutes 25
    .\demo.ps1 -Scenario azure -ContextualTroubleshooting -SupportEscalation
    .\demo.ps1 -Scenario clab -PreflightOnly     # just make the lab clean
#>

[CmdletBinding()]
param(
    [ValidateSet('azure','clab')]
    [string]$Scenario = 'clab',
    [string]$FaultName = "",
    [switch]$Interactive,
    [switch]$Timeline,
    [switch]$ContextualTroubleshooting,
    [switch]$SupportEscalation,
    [int]$TimeoutMinutes = 30,
    [int]$BaselineTimeoutMinutes = 15,
    [switch]$PreflightOnly,
    [switch]$NoWatch,
    [switch]$NoRevert,
    [string]$Prefix = "netsre",
    [Alias("g")][string]$ResourceGroup = "netsre-rg"
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

function Write-Info { param([string]$Msg) Write-Host "[INFO]   $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]     $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]   $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "[ERROR]  $Msg" -ForegroundColor Red }
function Banner { param([string]$Title)
    Write-Host ""
    Write-Host "═════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "  $Title" -ForegroundColor Magenta
    Write-Host "═════════════════════════════════════════════════════════════" -ForegroundColor Magenta
}
function Pause-Step { param([string]$Next)
    if ($Interactive) { Read-Host ">> Press Enter to $Next" | Out-Null }
}

# ── Timeline recorder ────────────────────────────────────────────────────────
$script:Events = New-Object System.Collections.Generic.List[object]
$script:T0 = $null   # set at fault injection; deltas are measured from here
$script:AgentReverted = $false   # set true if the SRE Agent restores connectivity on its own

function Record-Event {
    param([string]$Label, [datetime]$When = [datetime]::UtcNow, [string]$Detail = "")
    $utc = $When.ToUniversalTime()
    $script:Events.Add([pscustomobject]@{ Time = $utc; Label = $Label; Detail = $Detail })
    if ($Timeline) {
        $deltaStr = "  --  "
        if ($script:T0) {
            $span = $utc - $script:T0
            $sign = if ($span.Ticks -lt 0) { '-' } else { '+' }
            $mag  = [timespan]::FromTicks([math]::Abs($span.Ticks))
            $deltaStr = '{0}{1:00}:{2:00}' -f $sign, [int]$mag.TotalMinutes, $mag.Seconds
        }
        $line = "  ⏱ {0}Z  (T{1})  {2}" -f $utc.ToString('HH:mm:ss'), $deltaStr, $Label
        if ($Detail) { $line += " — $Detail" }
        Write-Host $line -ForegroundColor Magenta
    }
}

function Show-Timeline {
    if (-not $Timeline -or $script:Events.Count -eq 0) { return }
    Banner "TIMELINE — event cascade (T0 = fault injected)"
    Write-Host ("  {0,-10} {1,-9} {2}" -f "UTC", "T+", "Event") -ForegroundColor DarkGray
    foreach ($e in ($script:Events | Sort-Object Time)) {
        $deltaStr = "   --   "
        if ($script:T0) {
            $span = $e.Time - $script:T0
            $sign = if ($span.Ticks -lt 0) { '-' } else { '+' }
            $mag  = [timespan]::FromTicks([math]::Abs($span.Ticks))
            $deltaStr = '{0}{1:00}:{2:00}' -f $sign, [int]$mag.TotalMinutes, $mag.Seconds
        }
        $lbl = $e.Label
        if ($e.Detail) { $lbl += "  ($($e.Detail))" }
        Write-Host ("  {0,-10} {1,-9} {2}" -f ($e.Time.ToString('HH:mm:ss')), $deltaStr, $lbl)
    }
    Write-Host ""
}

# ── Azure / data-plane helpers ───────────────────────────────────────────────
$script:LawId = $null
function Get-LawId {
    if ($script:LawId) { return $script:LawId }
    $script:LawId = az monitor log-analytics workspace show -g $ResourceGroup -n "$Prefix-law" --query customerId -o tsv 2>$null
    return $script:LawId
}

$script:SubId = $null
function Get-SubId {
    if (-not $script:SubId) { $script:SubId = az account show --query id -o tsv 2>$null }
    return $script:SubId
}

function Assert-AzLogin {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." }
    Write-Ok "Azure CLI logged in — subscription: $($acct.name)"
}

# Latest Connection Monitor test result rows for a given SourceName (via Log Analytics).
function Get-CmResults {
    param([string]$SourceName, [int]$Mins = 15)
    $law = Get-LawId
    if (-not $law) { return @() }
    $kql = "NWConnectionMonitorTestResult | where TimeGenerated > ago(${Mins}m) | where SourceName == '$SourceName' | summarize arg_max(TimeGenerated, *) by TestGroupName, DestinationName | project TestGroupName, DestinationName, TestResult, TimeGenerated | order by TestGroupName asc"
    try {
        $out = az monitor log-analytics query --workspace $law --analytics-query $kql -o json 2>$null | ConvertFrom-Json
        return @($out)
    } catch { return @() }
}

# Latest Connection Monitor test result rows for EVERY source in the environment.
function Get-AllCmResults {
    param([int]$Mins = 20)
    $law = Get-LawId
    if (-not $law) { return @() }
    $kql = "NWConnectionMonitorTestResult | where TimeGenerated > ago(${Mins}m) | summarize arg_max(TimeGenerated, *) by SourceName, DestinationName, TestGroupName | project SourceName, DestinationName, TestGroupName, TestResult, TimeGenerated | order by SourceName asc, TestGroupName asc"
    try {
        $out = az monitor log-analytics query --workspace $law --analytics-query $kql -o json 2>$null | ConvertFrom-Json
        return @($out)
    } catch { return @() }
}
function Get-FiredAlert {
    param([string]$NameLike, [datetime]$SinceUtc)
    $sub = Get-SubId
    if (-not $sub) { return $null }
    $url = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1h"
    try { $a = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json } catch { return $null }
    if (-not $a) { return $null }
    $a.value |
        Where-Object { $_.name -like "$NameLike*" } |
        Where-Object { $_.properties.essentials.monitorCondition -eq 'Fired' } |
        Where-Object { $_.properties.essentials.startDateTime -and ([datetime]$_.properties.essentials.startDateTime).ToUniversalTime() -ge $SinceUtc.AddSeconds(-90) } |
        Sort-Object { [datetime]$_.properties.essentials.startDateTime } |
        Select-Object -First 1
}

# Earliest matching Syslog row after $SinceUtc (best-effort; the FRR→host forwarder
# may not always deliver, so callers treat $null as "not observed").
function Get-SyslogHit {
    param([string[]]$Substrings, [datetime]$SinceUtc)
    if (-not $Substrings -or $Substrings.Count -eq 0) { return $null }
    $law = Get-LawId
    if (-not $law) { return $null }
    $hasExpr  = ($Substrings | ForEach-Object { "SyslogMessage has '$_'" }) -join ' or '
    $sinceIso = $SinceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $kql = "Syslog | where TimeGenerated > datetime($sinceIso) | where $hasExpr | summarize minT = min(TimeGenerated), sample = take_any(SyslogMessage)"
    try { $r = az monitor log-analytics query --workspace $law --analytics-query $kql -o json 2>$null | ConvertFrom-Json } catch { return $null }
    if ($r -and $r.minT) { return $r } else { return $null }
}

# ── Agent data-plane (threads) — to detect the incident the fault opens ──────
$script:AgentName = ""
$script:AgentEndpoint = ""
$script:DpToken = $null
$script:DpTokenAt = [datetime]::MinValue
$DataPlaneResource = "https://azuresre.dev"

function Resolve-Agent {
    if ($script:AgentEndpoint) { return }
    $cfg = "$here\..\sre-agent-config\config.yaml"
    if (Test-Path $cfg) {
        $inAgent = $false
        foreach ($line in Get-Content $cfg) {
            if ($line -match '^\s*agent:\s*$') { $inAgent = $true; continue }
            if ($inAgent) {
                if ($line -match '^\S') { break }
                if (-not $script:AgentName -and $line -match '^\s+name:\s*(\S+)') { $script:AgentName = $matches[1] }
            }
        }
    }
    if (-not $script:AgentName) { $script:AgentName = "$Prefix-sre-agent" }
    $script:AgentEndpoint = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $script:AgentName --query "properties.agentEndpoint" -o tsv 2>$null
}

# Verify the agent's global autonomy mode. Autonomous is required for it to
# remediate on-camera (Manual/ReadOnly only propose). Offer to switch it.
function Ensure-AgentAutonomous {
    Resolve-Agent
    if (-not $script:AgentName) { Write-Warn "Could not resolve the SRE Agent name — skipping autonomy check."; return }
    $mode = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $script:AgentName --query "properties.actionConfiguration.mode" -o tsv 2>$null
    if (-not $mode) { Write-Warn "Could not read the agent's mode — verify manually in the portal (Autonomous recommended)."; return }
    if ($mode -eq 'Autonomous') { Write-Ok "SRE Agent mode: Autonomous — it will remediate on-camera."; return }

    Write-Warn "SRE Agent mode is '$mode' (not Autonomous) — it will only PROPOSE fixes, not apply them on-camera."
    $switch = $true
    if ($Interactive) {
        $ans = Read-Host "Switch the agent to Autonomous now? (Y/n)"
        $switch = ($ans -notmatch '^(n|no)$')
    } else {
        Write-Info "Switching the agent to Autonomous automatically (non-interactive)."
    }
    if (-not $switch) { Write-Warn "Left the agent in '$mode' mode — it will not remediate autonomously."; return }

    $id = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $script:AgentName --query id -o tsv 2>$null
    if (-not $id) { Write-Warn "Could not resolve the agent resource id — set Autonomous manually in the portal."; return }
    Write-Info "Setting properties.actionConfiguration.mode = Autonomous..."
    az resource update --ids $id --set properties.actionConfiguration.mode=Autonomous -o none 2>$null
    Start-Sleep 5
    $now = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $script:AgentName --query "properties.actionConfiguration.mode" -o tsv 2>$null
    if ($now -eq 'Autonomous') { Write-Ok "SRE Agent switched to Autonomous."; Record-Event "SRE Agent set to Autonomous" }
    else { Write-Warn "Mode is still '$now' after the update — the toggle has a propagation lag; verify on a freshly-loaded portal tab." }
}

function Get-DpToken {
    if (-not $script:DpToken -or ([datetime]::UtcNow - $script:DpTokenAt).TotalMinutes -gt 40) {
        $script:DpToken = az account get-access-token --resource $DataPlaneResource --query accessToken -o tsv 2>$null
        $script:DpTokenAt = [datetime]::UtcNow
    }
    return $script:DpToken
}

function Get-NewIncident {
    param([datetime]$SinceUtc, [string]$TitleContains)
    Resolve-Agent
    if (-not $script:AgentEndpoint) { return $null }
    $tok = Get-DpToken
    if (-not $tok) { return $null }
    try {
        $h = @{ Authorization = "Bearer $tok"; Accept = "application/json" }
        $threads = (Invoke-RestMethod -Uri "$($script:AgentEndpoint)/api/v1/threads" -Headers $h -Method Get).value
    } catch { return $null }
    $threads |
        Where-Object { $_.source -eq 'Incident' } |
        Where-Object { -not $TitleContains -or ($_.title -like "*$TitleContains*") } |
        Where-Object { $_.createdTimestamp -and ([datetime]$_.createdTimestamp).ToUniversalTime() -ge $SinceUtc.AddSeconds(-30) } |
        Sort-Object { [datetime]$_.createdTimestamp } |
        Select-Object -First 1
}

# ── Pre-flight building blocks ───────────────────────────────────────────────
# Start EVERY deallocated/stopped VM in the RG so all Connection Monitors can go
# green — a down source OR destination VM fails its CM and fires unrelated alerts.
function Ensure-AllVmsRunning {
    Write-Info "Enumerating lab VMs in $ResourceGroup..."
    $vms = az vm list -g $ResourceGroup -d -o json 2>$null | ConvertFrom-Json
    if (-not $vms) { Write-Warn "No VMs found in $ResourceGroup."; return }
    $toStart = @()
    foreach ($v in $vms) {
        if ($v.powerState -eq 'VM running') { Write-Ok "$($v.name): running" }
        else { Write-Info "$($v.name): $($v.powerState) — starting..."; az vm start -g $ResourceGroup -n $v.name --no-wait -o none; $toStart += $v.name }
    }
    if ($toStart.Count -eq 0) { Write-Ok "All VMs already running."; return }
    Write-Info "Waiting for $($toStart.Count) VM(s) to reach 'running'..."
    $deadline = (Get-Date).AddMinutes(8)
    $pending = $toStart
    do {
        Start-Sleep 15
        $vms = az vm list -g $ResourceGroup -d -o json 2>$null | ConvertFrom-Json
        $pending = @($vms | Where-Object { $toStart -contains $_.name -and $_.powerState -ne 'VM running' } | ForEach-Object { $_.name })
        if ($pending.Count) { Write-Info "  still starting: $($pending -join ', ')" }
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($pending.Count -eq 0) { Write-Ok "All $($toStart.Count) started VM(s) running." }
    else { Write-Warn "Not running after wait: $($pending -join ', ') — their CMs may report Unknown." }
    Record-Event "All lab VMs running" -Detail "$($toStart.Count) started"
}

# App Gateways front the webapp Traffic Manager profile. When they are Stopped the
# TM endpoints go Degraded and the onprem-to-webapp Connection Monitor fails (rtt=None),
# so the baseline is never fully green. Start any stopped App Gateways and wait for them.
function Ensure-AppGatewaysRunning {
    Write-Info "Enumerating Application Gateways in $ResourceGroup..."
    $gws = az network application-gateway list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
    if (-not $gws) { Write-Info "No Application Gateways in $ResourceGroup."; return }
    $toStart = @()
    foreach ($g in $gws) {
        $st = az network application-gateway show -g $ResourceGroup -n $g.name --query "operationalState" -o tsv 2>$null
        if ($st -eq 'Running') { Write-Ok "$($g.name): running" }
        else { Write-Info "$($g.name): $st — starting..."; az network application-gateway start -g $ResourceGroup -n $g.name --no-wait -o none; $toStart += $g.name }
    }
    if ($toStart.Count -eq 0) { Write-Ok "All Application Gateways already running."; return }
    Write-Info "Waiting for $($toStart.Count) App Gateway(s) to reach 'Running' (can take a few minutes)..."
    $deadline = (Get-Date).AddMinutes(8)
    $pending = $toStart
    do {
        Start-Sleep 20
        $pending = @()
        foreach ($n in $toStart) {
            $st = az network application-gateway show -g $ResourceGroup -n $n --query "operationalState" -o tsv 2>$null
            if ($st -ne 'Running') { $pending += $n }
        }
        if ($pending.Count) { Write-Info "  still starting: $($pending -join ', ')" }
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($pending.Count -eq 0) { Write-Ok "All $($toStart.Count) App Gateway(s) running." }
    else { Write-Warn "Not running after wait: $($pending -join ', ') — onprem-to-webapp CM may stay red (TM endpoints Degraded)." }
    Record-Event "App Gateways running" -Detail "$($toStart.Count) started"
}

# The clab host-probe wiring (veth clabr1host IP + host route) is NOT durable across
# a VM reboot OR a `containerlab deploy --reconfigure` (which recreates the veth
# without its IP). When the wiring is missing, a STALE route sends the probe over the
# docker management bridge (172.20.20.0/24) straight to the in-fabric host container —
# so `ping 172.31.20.10` still succeeds but BYPASSES the r1→r2 fabric, and no fabric
# fault (OSPF/BGP) can ever turn the Connection Monitor red. We therefore (1) re-apply
# the cloud-init wiring idempotently and (2) VERIFY the probe egresses `clabr1host`
# (the fabric), not the mgmt bridge — pinging alone is not sufficient.
function Ensure-ClabFabric {
    $ClabVm = "$Prefix-onprem-clab"
    Write-Info "Ensuring clab host-probe path traverses the FABRIC (veth clabr1host → r1 → r2 → 172.31.20.10)..."
    $wire = @'
set -uo pipefail
if ip link show clabr1host >/dev/null 2>&1; then
  ip addr replace 172.31.11.1/30 dev clabr1host
  ip link set dev clabr1host up
  ip route replace 172.31.20.0/24 via 172.31.11.2 dev clabr1host
  DEV=$(ip route get 172.31.20.10 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  echo "PROBE_DEV=$DEV"
  if ping -c2 -W2 172.31.20.10 >/dev/null 2>&1; then echo "PING=ok"; else echo "PING=fail"; fi
else
  echo "PROBE_DEV=none"; echo "PING=fail"
fi
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wire))
    $run = az vm run-command invoke -g $ResourceGroup -n $ClabVm --command-id RunShellScript `
        --scripts "echo $b64 | base64 -d | bash" -o json 2>$null | ConvertFrom-Json
    $out = if ($run) { ($run.value[0].message) } else { "" }
    $dev  = if ($out -match 'PROBE_DEV=(\S+)') { $matches[1] } else { '' }
    $ping = if ($out -match 'PING=(\S+)')      { $matches[1] } else { '' }

    if ($dev -eq 'clabr1host' -and $ping -eq 'ok') {
        Write-Ok "clab fabric healthy — probe egresses veth 'clabr1host' (through r1→r2), 0% loss."
        return
    }
    if ($dev -eq 'none') {
        Write-Warn "veth 'clabr1host' is missing — the fabric is not deployed. Rebuilding via on-VM helper..."
        az vm run-command invoke -g $ResourceGroup -n $ClabVm --command-id RunShellScript `
            --scripts "/usr/local/bin/onprem-clab-up.sh" -o none
        Start-Sleep 15
    } elseif ($dev -and $dev -ne 'clabr1host') {
        Write-Warn "Probe was egressing '$dev' (NOT the fabric) — a stale mgmt-bridge route was short-circuiting it. Re-wired to clabr1host; re-verifying..."
    } else {
        Write-Warn "clab probe not healthy yet (dev='$dev' ping='$ping') — re-applying wiring and re-verifying..."
    }

    # Re-apply + re-verify (covers both the redeploy and the re-wire cases).
    $run2 = az vm run-command invoke -g $ResourceGroup -n $ClabVm --command-id RunShellScript `
        --scripts "echo $b64 | base64 -d | bash" -o json 2>$null | ConvertFrom-Json
    $out2 = if ($run2) { ($run2.value[0].message) } else { "" }
    $dev2  = if ($out2 -match 'PROBE_DEV=(\S+)') { $matches[1] } else { '' }
    $ping2 = if ($out2 -match 'PING=(\S+)')      { $matches[1] } else { '' }
    if ($dev2 -eq 'clabr1host' -and $ping2 -eq 'ok') {
        Write-Ok "clab fabric ready — probe egresses veth 'clabr1host' (through r1→r2), 0% loss."
    } else {
        Write-Warn "clab probe still not clean (dev='$dev2' ping='$ping2') — investigate before recording; a fabric fault may not be detectable."
    }
}

# Poll EVERY Connection Monitor in the environment until all latest results are Pass.
function Wait-AllCmGreen {
    param([int]$TimeoutMin = 15)
    Write-Info "Waiting for ALL Connection Monitors in the environment to go GREEN (up to $TimeoutMin min)..."
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        $r = @(Get-AllCmResults -Mins 20)
        if ($r.Count -gt 0) {
            $bad = @($r | Where-Object { $_.TestResult -ne 'Pass' })
            if ($bad.Count -eq 0) {
                Write-Ok "Baseline GREEN — all $($r.Count) Connection Monitor test(s) passing."
                Record-Event "All Connection Monitors GREEN" -Detail "$($r.Count) tests"
                return $true
            }
            $summary = ($bad | ForEach-Object { "$($_.TestGroupName)[$($_.SourceName)->$($_.DestinationName)]=$($_.TestResult)" }) -join ', '
            Write-Info "  $($bad.Count)/$($r.Count) not yet Pass ($summary) — waiting..."
        } else {
            Write-Info "  no recent CM data yet (agents re-reporting after boot) — waiting..."
        }
        Start-Sleep 30
    }
    Write-Warn "Not all Connection Monitors green within $TimeoutMin min — proceeding anyway (check the summary above)."
    return $false
}

# ── Curated scenarios (fault + the signals to watch) ─────────────────────────
$curated = @{
    azure = @{
        Fault     = 'udr-wrong-nexthop'
        Title     = ''                    # any new incident (Azure CM alert)
        CmSource  = "$Prefix-spoke11-vm"  # CM source whose default route is black-holed
        AlertLike = "$Prefix-cm-"         # netsre-cm-checks-failed / -test-result-fail
        Syslog    = @()                   # UDR fault produces no syslog
        Story  = "Spoke11's default route (0.0.0.0/0 → NVA) is repointed to an unreachable next-hop (10.255.255.1). Traffic black-holes; every resource still reports healthy. Spoke11 Connection Monitors fail → Azure Monitor alert → the agent must trace effective routes to the bad UDR."
        Expect = "Watch for: incident on 'netsre-cm-checks-failed'; the agent pulls effective routes / route tables and localizes the black-hole to the spoke11 UDR next-hop."
        Impact = "User transactions sourced from spoke11 cannot reach dependencies that rely on the default route; unrelated spokes may remain healthy."
        ResourcePicker = "$Prefix-spoke11-vnet or $Prefix-spoke11-rt"
        Diagnostics = @(
            "az network nic show-effective-route-table -g $ResourceGroup -n ${Prefix}-spoke11-vm-nic -o table"
            "az network route-table route list -g $ResourceGroup --route-table-name ${Prefix}-spoke11-rt -o table"
            ".\scripts\check-health.ps1 -Sections 5,6"
        )
        Hypotheses = @(
            "NSG or guest firewall denial on the affected flow"
            "NVA IP-forwarding or health-probe failure"
            "Peering or VPN transit failure outside spoke11"
        )
    }
    clab = @{
        Fault     = 'clab-ospf-area-mismatch'
        Title     = 'clab'                # clab CM incident title contains 'clab'
        CmSource  = "$Prefix-onprem-clab" # containerlab lab-host VM (also the CM source)
        AlertLike = "$Prefix-clab-cm-"    # netsre-clab-cm-checks-failed / -test-result-fail
        Syslog    = @('ADJCHANGE','Nbr','neighbor','OSPF')  # FRR bgpd/ospfd messages
        Story  = "On the on-prem fabric, r1's transit OSPF area is flipped (0 → 1). The adjacency drops, r2's loopback is withdrawn, the BGP session (which peers over the loopbacks) tears down, the LAN 172.31.20.0/24 is withdrawn — the clab Connection Monitor fails and bgpd logs to syslog."
        Expect = "Watch for: incident on 'netsre-clab-cm-*'; the agent follows the on-prem-fabric-triage skill, docker-execs into the FRR routers, checks OSPF FIRST, and roots the cause at the OSPF area mismatch (not the downstream BGP symptom)."
        Impact = "Azure-to-on-prem user traffic cannot reach the containerlab LAN while Azure-only paths may remain healthy."
        ResourcePicker = "$Prefix-onprem-clab virtual machine"
        Diagnostics = @(
            "az vm run-command invoke -g $ResourceGroup -n ${Prefix}-onprem-clab --command-id RunShellScript --scripts `"docker exec clab-onprem-onprem-r1 vtysh -c 'show ip ospf neighbor'`""
            "az vm run-command invoke -g $ResourceGroup -n ${Prefix}-onprem-clab --command-id RunShellScript --scripts `"docker exec clab-onprem-onprem-r1 vtysh -c 'show bgp ipv4 unicast summary'`""
            ".\scripts\check-health.ps1 -Sections 9"
        )
        Hypotheses = @(
            "BGP policy or session failure independent of OSPF"
            "Containerlab host-veth probe path bypass or loss"
            "Azure VPN or GatewaySubnet routing failure"
        )
    }
}

$fault = if ($FaultName) { $FaultName } else { $curated[$Scenario].Fault }
$titleFilter = if ($FaultName) { '' } else { $curated[$Scenario].Title }
$meta = $curated[$Scenario]
if ($FaultName) {
    $meta = $meta.Clone()
    $meta.Story = "Custom fault scenario '$FaultName' produced the observed connectivity incident."
    $meta.Impact = "Connectivity impact depends on the selected fault; preserve the observed affected and healthy paths in the case."
    $meta.ResourcePicker = "$ResourceGroup resource group"
    $meta.Diagnostics = @(
        ".\scripts\check-health.ps1"
        ".\scripts\inject-fault.ps1 -Scenario $FaultName -Revert"
        "az monitor metrics alert list -g $ResourceGroup -o table"
    )
    $meta.Hypotheses = @(
        "The configured fault did not affect the intended data path"
        "An unrelated baseline failure contributed to the symptoms"
        "The alert and incident were correlated from different time windows"
    )
}

function Show-ContextualTroubleshootingStep {
    param($Metadata)
    Banner "OPTIONAL PRESENTER STEP - PORTAL CONTEXTUAL TROUBLESHOOTING"
    Write-Host "  Portal: Azure SRE Agent -> Troubleshoot -> Add resource -> $($Metadata.ResourcePicker)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Exact prompt:" -ForegroundColor Yellow
    Write-Host "  Investigate connectivity for the selected resource in $ResourceGroup. Establish the current healthy baseline, identify affected and healthy paths, inspect topology and recent changes, and rank likely causes with evidence. Do not remediate yet; return the diagnostics you would run and the rollback-safe next action." -ForegroundColor White
    Write-Host ""
    Write-Info "This presenter branch starts from resource context; the autonomous workflow below still starts from the alert."
}

function Show-SupportEscalationPackage {
    param($Metadata, [string]$Reason)
    Banner "SUPPORT ESCALATION PACKAGE"
    Write-Host "Reason" -ForegroundColor Yellow
    Write-Host "  $Reason"
    Write-Host "Symptoms" -ForegroundColor Yellow
    Write-Host "  $($Metadata.Story)"
    Write-Host "Business impact" -ForegroundColor Yellow
    Write-Host "  $($Metadata.Impact)"
    Write-Host "Evidence and signals" -ForegroundColor Yellow
    if ($script:Events.Count -eq 0) {
        Write-Host "  No timeline events were captured; collect current Connection Monitor, alert, and incident state."
    } else {
        foreach ($event in ($script:Events | Sort-Object Time)) {
            $detail = if ($event.Detail) { " - $($event.Detail)" } else { "" }
            Write-Host "  $($event.Time.ToString('o')) $($event.Label)$detail"
        }
    }
    Write-Host "Diagnostics and exact commands" -ForegroundColor Yellow
    foreach ($command in $Metadata.Diagnostics) {
        Write-Host "  $command"
    }
    Write-Host "Remaining hypotheses" -ForegroundColor Yellow
    foreach ($hypothesis in $Metadata.Hypotheses) {
        Write-Host "  - $hypothesis"
    }
    Write-Host "Requested support outcome" -ForegroundColor Yellow
    Write-Host "  Validate the localized layer, identify a rollback-safe remediation, and state the post-change connectivity test."
}

Banner "SRE AGENT LIVE DEMO  —  scenario: $Scenario  (fault: $fault)"
if (-not $FaultName) {
    Write-Host "STORY:  $($meta.Story)" -ForegroundColor White
    Write-Host ""
    Write-Host "$($meta.Expect)" -ForegroundColor DarkYellow
}
Write-Host ""
Write-Info "Resource group: $ResourceGroup    Prefix: $Prefix"
Write-Info "Autonomy: pre-flight verifies the agent is in Autonomous mode and offers to switch it if not."
if ($Timeline) { Write-Info "Timeline mode ON — timestamping actions and watching for each cascade event." }

# ── 0. Pre-flight — ALWAYS runs, auto-fixes to reach a clean baseline ────────
Pause-Step "run PRE-FLIGHT (start all VMs, clear incidents, wait for CMs green)"
Banner "STEP 0 — Pre-flight: make the lab clean before the fault"
Assert-AzLogin
Ensure-AllVmsRunning
Ensure-AppGatewaysRunning
if ($Scenario -eq 'clab') { Ensure-ClabFabric }
Write-Info "Deleting any existing SRE Agent incidents (so the fault opens a fresh one)..."
& "$here\clear-incidents.ps1" -Force
Record-Event "Existing incidents cleared"
Wait-AllCmGreen -TimeoutMin $BaselineTimeoutMinutes | Out-Null
Ensure-AgentAutonomous
Write-Ok "Pre-flight complete — clean baseline ready."

if ($PreflightOnly) {
    Show-Timeline
    Banner "PRE-FLIGHT ONLY — lab is clean and warm. Re-run without -PreflightOnly to inject and record."
    return
}

if ($ContextualTroubleshooting) {
    Show-ContextualTroubleshootingStep -Metadata $meta
    Pause-Step "continue from contextual troubleshooting to the autonomous alert workflow"
}

# ── 1. Inject the fault (T0) ────────────────────────────────────────────────
Pause-Step "INJECT the fault"
Banner "STEP 1 — Inject fault: $fault"
$injectUtc = [datetime]::UtcNow
$script:T0 = $injectUtc
& "$here\inject-fault.ps1" -Scenario $fault -ResourceGroup $ResourceGroup -Prefix $Prefix
Record-Event "Fault injected (T0)" $injectUtc -Detail $fault
Write-Ok "Fault injected. The Connection Monitor must fail and the metric alert must fire"
Write-Info "before the agent's ~1-min scanner opens an incident — expect a few minutes of latency."

# ── 2. Watch the investigation ──────────────────────────────────────────────
if (-not $NoWatch) {
    Pause-Step "WATCH the agent investigate"
    Banner "STEP 2 — Watch the agent detect → investigate → root-cause"

    if ($Timeline) {
        # Actively watch each cascade event until the incident opens (or timeout),
        # recording the true event time of each, then hand off to the message tailer.
        Write-Info "Watching cascade events (CM red → syslog → alert → incident)..."
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $seen = @{ cmred = $false; syslog = $false; alert = $false }
        $incident = $null
        while (-not $incident -and (Get-Date) -lt $deadline) {
            if (-not $seen.cmred) {
                $red = @(Get-CmResults -SourceName $meta.CmSource -Mins 15 |
                    Where-Object { $_.TestResult -eq 'Fail' -and ([datetime]$_.TimeGenerated).ToUniversalTime() -ge $injectUtc })
                if ($red.Count) { $seen.cmred = $true; Record-Event "Connection Monitor RED" ([datetime]$red[0].TimeGenerated) -Detail $red[0].TestGroupName }
            }
            if (-not $seen.syslog -and $meta.Syslog.Count) {
                $sys = Get-SyslogHit -Substrings $meta.Syslog -SinceUtc $injectUtc
                if ($sys) { $seen.syslog = $true; $s = ($sys.sample -replace '\s+',' '); if ($s.Length -gt 60) { $s = $s.Substring(0,60) + '…' }; Record-Event "Syslog (BGP/OSPF) received" ([datetime]$sys.minT) -Detail $s }
            }
            if (-not $seen.alert) {
                $al = Get-FiredAlert -NameLike $meta.AlertLike -SinceUtc $injectUtc
                if ($al) { $seen.alert = $true; Record-Event "Metric alert FIRED" ([datetime]$al.properties.essentials.startDateTime) -Detail $al.name }
            }
            $incident = Get-NewIncident -SinceUtc $injectUtc -TitleContains $titleFilter
            if ($incident) { Record-Event "SRE Agent incident CREATED" ([datetime]$incident.createdTimestamp) -Detail $incident.title }
            if (-not $incident) {
                $elapsed = ((Get-Date).ToUniversalTime() - $injectUtc)
                $pend = @()
                if (-not $seen.cmred) { $pend += 'CM-red' }
                if ($meta.Syslog.Count -and -not $seen.syslog) { $pend += 'syslog' }
                if (-not $seen.alert) { $pend += 'alert' }
                $pend += 'incident'
                Write-Info ("  T+{0:mm\:ss} — waiting for: {1}" -f $elapsed, ($pend -join ', '))
                Start-Sleep 20
            }
        }

        if ($incident) {
            $remaining = [Math]::Max(2, [int]($deadline - (Get-Date)).TotalMinutes)
            & "$here\watch-incidents.ps1" -ThreadId $incident.id -TimeoutMinutes $remaining -Quiet -TailMessages 2 -StallMinutes 3 | Out-Null
            Record-Event "Investigation ended (final messages shown)"
            # Best-effort recovery capture (autonomous remediation closing the loop).
            Write-Info "Checking whether the agent restored connectivity (CM green again) for up to 5 min..."
            $recDeadline = (Get-Date).AddMinutes(5)
            while (-not $script:AgentReverted -and (Get-Date) -lt $recDeadline) {
                $r = @(Get-CmResults -SourceName $meta.CmSource -Mins 10)
                if ($r.Count -gt 0 -and @($r | Where-Object { $_.TestResult -ne 'Pass' }).Count -eq 0) {
                    $script:AgentReverted = $true; Record-Event "Connection Monitor recovered GREEN"
                }
                if (-not $script:AgentReverted) { Start-Sleep 30 }
            }
        } else {
            Write-Warn "No incident detected within $TimeoutMinutes min. Check the alert fired and the agent scanner."
        }
    } else {
        & "$here\watch-incidents.ps1" -TitleContains $titleFilter -SinceUtc $injectUtc -TimeoutMinutes $TimeoutMinutes -Quiet -TailMessages 2 -StallMinutes 3 | Out-Null
    }
} else {
    Write-Warn "NoWatch set — skipping the live investigation stream."
}

# Refresh the observable remediation state before deciding whether escalation is
# needed. Non-timeline runs do not otherwise set AgentReverted during the watch.
if (-not $script:AgentReverted) {
    $rr = @(Get-CmResults -SourceName $meta.CmSource -Mins 10)
    if ($rr.Count -gt 0 -and @($rr | Where-Object { $_.TestResult -ne 'Pass' }).Count -eq 0) {
        $script:AgentReverted = $true
    }
}

if ($SupportEscalation) {
    $escalationReason = if ($NoWatch) {
        "Autonomous investigation or remediation was not observed in this run."
    } elseif ($script:AgentReverted) {
        "Escalation was requested after automated recovery; use the package for follow-up and recurrence prevention."
    } else {
        "No safe and successful autonomous remediation was observed before presenter cleanup."
    }
    Show-SupportEscalationPackage -Metadata $meta -Reason $escalationReason
}

# ── 3. Revert ───────────────────────────────────────────────────────────────
# Before touching anything, verify whether the SRE Agent already remediated the
# fault on its own — the scenario's Connection Monitor being GREEN again is the
# observable signal. If so, there is nothing to revert (a manual revert would be
# a no-op) and we tell the user rather than blindly re-applying.
if ($NoRevert) {
    Write-Warn "NoRevert set — fault '$fault' will NOT be reverted by this script."
    if ($script:AgentReverted) { Write-Ok "Note: the SRE Agent already restored connectivity (CM green)." }
    else { Write-Host "    .\scripts\inject-fault.ps1 -Scenario $fault -Revert" -ForegroundColor Yellow }
}
elseif ($script:AgentReverted) {
    Banner "STEP 3 — Revert"
    Write-Ok "The SRE Agent appears to have ALREADY remediated the fault — '$($meta.CmSource)' Connection Monitor is GREEN again."
    $doRevert = $false
    if ($Interactive) {
        $ans = Read-Host "Agent already fixed it. Run the manual revert anyway to guarantee a clean baseline? (y/N)"
        $doRevert = ($ans -match '^(y|yes)$')
    } else {
        Write-Info "Skipping manual revert — the environment is already clean. (Run with -Interactive to override.)"
    }
    if ($doRevert) {
        & "$here\inject-fault.ps1" -Scenario $fault -ResourceGroup $ResourceGroup -Prefix $Prefix -Revert
        Record-Event "Fault reverted (manual, after agent fix)"
        Write-Ok "Fault reverted — environment restored."
    }
}
else {
    Pause-Step "REVERT the fault (agent did NOT restore it — CM still red)"
    Banner "STEP 3 — Revert fault: $fault"
    Write-Info "The SRE Agent did not restore connectivity on its own; reverting the injected fault."
    & "$here\inject-fault.ps1" -Scenario $fault -ResourceGroup $ResourceGroup -Prefix $Prefix -Revert
    Record-Event "Fault reverted"
    Write-Ok "Fault reverted — environment restored."
}

Show-Timeline
Banner "DEMO COMPLETE — scenario: $Scenario"
Write-Info "Tip: keep the portal incident thread open on-screen for the full transcript."
