<#
.SYNOPSIS
    One-command SRE Agent live demo: clear → inject → watch → revert.

.DESCRIPTION
    Runs an end-to-end, on-camera demonstration of the Azure SRE Agent detecting,
    investigating and (in Autonomous mode) remediating a networking fault:

      0. Ensure the lab is up — verify az login, start the scenario's Connection-Monitor
                                 source VMs if they are deallocated, and (for clab) rebuild
                                 the containerlab fabric + host-probe wiring so a clean
                                 baseline exists BEFORE the fault is injected.
      1. Clear old incidents  — so the new alert opens a FRESH incident instead of
                                 merging into a stale one (see the mapping-limitations doc).
      2. Inject a fault       — one Azure fault or one containerlab fabric fault.
      3. Watch the agent      — live-tail the incident it opens: its plan, the
                                 diagnostics it runs, and its root-cause verdict.
      4. Revert the fault     — restore a clean environment for the next take.

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

.PARAMETER TimeoutMinutes
    How long to watch the investigation (default 30).

.PARAMETER SkipClear   Do not delete existing incidents first.
.PARAMETER SkipPreflight  Do not run Step 0 (assume the lab is already up: VMs running,
                          clab fabric + wiring in place). Use to save time on a warm lab.
.PARAMETER PreflightOnly  Run Step 0 (ensure the lab is up) and then stop — no clear,
                          inject, watch or revert. Use to warm/verify the lab before recording.
.PARAMETER NoWatch     Inject only; do not stream the investigation.
.PARAMETER NoRevert    Leave the fault injected at the end (you revert manually).
.PARAMETER Prefix / -ResourceGroup   Lab naming (defaults: netsre / netsre-rg).

.EXAMPLE
    .\demo.ps1 -Scenario clab -Interactive
    .\demo.ps1 -Scenario azure -TimeoutMinutes 25
    .\demo.ps1 -FaultName pe-dns-override -NoRevert
#>

[CmdletBinding()]
param(
    [ValidateSet('azure','clab')]
    [string]$Scenario = 'clab',
    [string]$FaultName = "",
    [switch]$Interactive,
    [int]$TimeoutMinutes = 30,
    [switch]$SkipClear,
    [switch]$SkipPreflight,
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

# ── Pre-flight helpers (Step 0: make sure the lab is up) ─────────────────────
function Assert-AzLogin {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." }
    Write-Ok "Azure CLI logged in — subscription: $($acct.name)"
}

function Get-VmPowerState {
    param([string]$Vm)
    $iv = az vm get-instance-view -g $ResourceGroup -n $Vm -o json 2>$null | ConvertFrom-Json
    if (-not $iv) { return $null }  # VM not found
    ($iv.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
}

function Ensure-VmsRunning {
    param([string[]]$Vms)
    $starting = @()
    foreach ($vm in $Vms) {
        $power = Get-VmPowerState $vm
        if ($null -eq $power) { Write-Warn "VM '$vm' not found — skipping (may not exist in this lab)."; continue }
        if ($power -eq 'PowerState/running') { Write-Ok "$vm already running." }
        else { Write-Info "$vm is '$power' — starting..."; az vm start -g $ResourceGroup -n $vm --no-wait -o none; $starting += $vm }
    }
    if ($starting.Count -eq 0) { return }
    $deadline = (Get-Date).AddMinutes(6)
    foreach ($vm in $starting) {
        do { Start-Sleep 10; $power = Get-VmPowerState $vm } while ($power -ne 'PowerState/running' -and (Get-Date) -lt $deadline)
        if ($power -eq 'PowerState/running') { Write-Ok "$vm running." } else { Write-Warn "$vm still '$power' after wait — the CM source may report Unknown." }
    }
}

# The clab host-probe wiring (veth clabr1host) and the FRR container fabric are
# NOT durable across a VM stop/start, so a warm-but-rebooted clab VM fails the CM
# with NO fault injected. The on-VM helper 'onprem-clab-up.sh' idempotently rebuilds
# the fabric AND re-applies the probe-link wiring; we only invoke it if the fast
# host→LAN reachability probe is already broken (don't rebuild a healthy fabric).
function Ensure-ClabFabric {
    Write-Info "Checking clab host-probe path ($ClabVm host → in-fabric LAN 172.31.20.10)..."
    $probe = az vm run-command invoke -g $ResourceGroup -n $ClabVm --command-id RunShellScript `
        --scripts "ping -c3 -W2 172.31.20.10 2>&1 | tail -3" -o json 2>$null | ConvertFrom-Json
    $msg = if ($probe) { $probe.value[0].message } else { "" }
    if ($msg -match '0% packet loss') { Write-Ok "clab fabric healthy — host→LAN 0% loss."; return }
    Write-Warn "clab host→LAN probe not clean (fabric/wiring gap after a reboot?). Rebuilding (idempotent)..."
    az vm run-command invoke -g $ResourceGroup -n $ClabVm --command-id RunShellScript `
        --scripts "/usr/local/bin/onprem-clab-up.sh" -o none
    Start-Sleep 15  # let OSPF/BGP converge and the LAN route re-install
    $probe2 = az vm run-command invoke -g $ResourceGroup -n $ClabVm --command-id RunShellScript `
        --scripts "ping -c3 -W2 172.31.20.10 2>&1 | tail -3" -o json 2>$null | ConvertFrom-Json
    $msg2 = if ($probe2) { $probe2.value[0].message } else { "" }
    if ($msg2 -match '0% packet loss') { Write-Ok "clab fabric rebuilt — host→LAN 0% loss." }
    else { Write-Warn "clab host→LAN still failing after rebuild. The demo may open an incident with no fault injected — investigate before recording." }
}

# ── Curated scenarios ────────────────────────────────────────────────────────
$curated = @{
    azure = @{
        Fault  = 'udr-wrong-nexthop'
        Title  = ''          # any new incident (Azure CM alert: "[SevX] netsre-cm-checks-failed")
        Vms    = @("$Prefix-spoke11-vm")   # CM source whose default route is black-holed
        Story  = "Spoke11's default route (0.0.0.0/0 → NVA) is repointed to an unreachable next-hop (10.255.255.1). Traffic black-holes; every resource still reports healthy. Spoke11 Connection Monitors fail → Azure Monitor alert → the agent must trace effective routes to the bad UDR."
        Expect = "Watch for: incident on 'netsre-cm-checks-failed'; the agent pulls effective routes / route tables and localizes the black-hole to the spoke11 UDR next-hop."
    }
    clab = @{
        Fault  = 'clab-ospf-area-mismatch'
        Title  = 'clab'      # clab CM incident title contains 'clab'
        Vms    = @("$Prefix-onprem-clab")  # containerlab lab-host VM (also the CM source)
        Story  = "On the on-prem fabric, r1's transit OSPF area is flipped (0 → 1). The adjacency drops, r2's loopback is withdrawn, the BGP session (which peers over the loopbacks) tears down, the LAN 172.31.20.0/24 is withdrawn — the clab Connection Monitor fails and bgpd logs to syslog."
        Expect = "Watch for: incident on 'netsre-clab-cm-*'; the agent follows the on-prem-fabric-triage skill, docker-execs into the FRR routers, checks OSPF FIRST, and roots the cause at the OSPF area mismatch (not the downstream BGP symptom)."
    }
}

$ClabVm = "$Prefix-onprem-clab"

$fault = if ($FaultName) { $FaultName } else { $curated[$Scenario].Fault }
$titleFilter = if ($FaultName) { '' } else { $curated[$Scenario].Title }
$meta = $curated[$Scenario]

Banner "SRE AGENT LIVE DEMO  —  scenario: $Scenario  (fault: $fault)"
if (-not $FaultName) {
    Write-Host "STORY:  $($meta.Story)" -ForegroundColor White
    Write-Host ""
    Write-Host "$($meta.Expect)" -ForegroundColor DarkYellow
}
Write-Host ""
Write-Info "Resource group: $ResourceGroup    Prefix: $Prefix"
Write-Info "Autonomy: the agent acts on whatever mode it is globally set to (Autonomous recommended)."

# ── 0. Pre-flight: make sure the lab is up ──────────────────────────────────
if (-not $SkipPreflight) {
    Pause-Step "run PRE-FLIGHT (verify login, start VMs, ensure clab fabric)"
    Banner "STEP 0/4 — Pre-flight: ensure the lab is up before injecting"
    Assert-AzLogin
    Ensure-VmsRunning $meta.Vms
    if ($Scenario -eq 'clab') { Ensure-ClabFabric }
    Write-Info "Reminder: confirm the agent is in AUTONOMOUS mode on a freshly-loaded portal tab"
    Write-Info "(the toggle has a propagation lag) so it remediates on-camera instead of only proposing."
    Write-Ok "Pre-flight complete — clean baseline ready."
} else {
    Write-Warn "SkipPreflight set — assuming VMs are running and the clab fabric/wiring is in place."
}

if ($PreflightOnly) {
    Banner "PRE-FLIGHT ONLY — lab is up. Re-run without -PreflightOnly to inject and record."
    return
}

# ── 1. Clear stale incidents ────────────────────────────────────────────────
if (-not $SkipClear) {
    Pause-Step "CLEAR existing incidents"
    Banner "STEP 1/4 — Clear stale incidents (avoid over-dedup / merge)"
    & "$here\clear-incidents.ps1" -Force
} else {
    Write-Warn "SkipClear set — existing incidents may absorb the new alert (over-merge)."
}

# ── 2. Inject the fault ─────────────────────────────────────────────────────
Pause-Step "INJECT the fault"
Banner "STEP 2/4 — Inject fault: $fault"
$injectUtc = [datetime]::UtcNow
Write-Info "Inject time (UTC): $($injectUtc.ToString('u'))"
& "$here\inject-fault.ps1" -Scenario $fault -ResourceGroup $ResourceGroup -Prefix $Prefix
Write-Ok "Fault injected. The Connection Monitor must fail and the metric alert must fire"
Write-Info "before the agent's ~1-min scanner opens an incident — expect a few minutes of latency."

# ── 3. Watch the investigation ──────────────────────────────────────────────
if (-not $NoWatch) {
    Pause-Step "WATCH the agent investigate"
    Banner "STEP 3/4 — Watch the agent detect → investigate → root-cause"
    & "$here\watch-incidents.ps1" -TitleContains $titleFilter -SinceUtc $injectUtc -TimeoutMinutes $TimeoutMinutes
} else {
    Write-Warn "NoWatch set — skipping the live investigation stream."
}

# ── 4. Revert ───────────────────────────────────────────────────────────────
if (-not $NoRevert) {
    Pause-Step "REVERT the fault"
    Banner "STEP 4/4 — Revert fault: $fault"
    & "$here\inject-fault.ps1" -Scenario $fault -ResourceGroup $ResourceGroup -Prefix $Prefix -Revert
    Write-Ok "Fault reverted — environment restored."
} else {
    Write-Warn "NoRevert set — fault '$fault' is STILL INJECTED. Revert with:"
    Write-Host "    .\scripts\inject-fault.ps1 -Scenario $fault -Revert" -ForegroundColor Yellow
}

Banner "DEMO COMPLETE — scenario: $Scenario"
Write-Info "Tip: keep the portal incident thread open on-screen for the full transcript."
