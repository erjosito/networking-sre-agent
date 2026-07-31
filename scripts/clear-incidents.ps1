<#
.SYNOPSIS
    Delete Azure SRE Agent incidents / threads (PowerShell).

.DESCRIPTION
    Lists and deletes SRE Agent incident *threads* via the agent data-plane API
    (DELETE /api/v1/threads/{id}). This is useful because the SRE Agent dedups /
    merges new alert firings into an existing open incident for the *same* alert
    rule: a stale, acknowledged or resolved incident will swallow a fresh firing
    instead of opening a new investigation. Clearing the stale incidents lets the
    next fault injection open a clean incident.

    By default the onboarding / "get to know each other" thread (which has no
    incidentId) is preserved. Use -All to delete it too.

    Requires: Azure CLI (`az`) logged in, with data-plane access to the agent
    endpoint (token audience https://azuresre.dev).

.PARAMETER ConfigFile
    Path to the agent manifest used to default AgentName / ResourceGroup
    (default: ../sre-agent-config/config.yaml).

.PARAMETER AgentName
    SRE Agent resource name (default: from config.yaml `agent.name`).

.PARAMETER ResourceGroup
    Resource group of the agent (default: from config.yaml `agent.resourceGroup`).

.PARAMETER TitleContains
    Only act on threads whose title contains this substring (case-insensitive),
    e.g. 'clab' or 'onprem'.

.PARAMETER Id
    One or more explicit thread IDs to delete. When given, other filters are
    ignored and the onboarding-protection is bypassed for those exact IDs.

.PARAMETER Status
    Only act on threads with this incident status (e.g. new, acknowledged,
    resolved).

.PARAMETER All
    Include the onboarding thread (threads with no incidentId) in the deletion.

.PARAMETER ListOnly
    List the matching threads and exit without deleting anything.

.PARAMETER Force
    Delete without the interactive confirmation prompt.

.EXAMPLE
    .\clear-incidents.ps1 -ListOnly
    .\clear-incidents.ps1 -TitleContains clab -Force
    .\clear-incidents.ps1 -Status acknowledged
    .\clear-incidents.ps1 -Id 5a456a03-c837-4e93-9c29-f91f9e45048d
    .\clear-incidents.ps1 -All -Force
#>

[CmdletBinding()]
param(
    [string]$ConfigFile    = "$PSScriptRoot\..\sre-agent-config\config.yaml",
    [string]$AgentName     = "",
    [string]$ResourceGroup = "",
    [string]$TitleContains = "",
    [string[]]$Id          = @(),
    [string]$Status        = "",
    [switch]$All,
    [switch]$ListOnly,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$DataPlaneResource = "https://azuresre.dev"

function Write-Info { param([string]$Msg) Write-Host "[INFO]   $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]     $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]   $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "[ERROR]  $Msg" -ForegroundColor Red }

# ── Resolve AgentName / ResourceGroup from the manifest if not supplied ──────
if ((-not $AgentName -or -not $ResourceGroup) -and (Test-Path $ConfigFile)) {
    $inAgent = $false
    foreach ($line in Get-Content $ConfigFile) {
        if ($line -match '^\s*agent:\s*$') { $inAgent = $true; continue }
        if ($inAgent) {
            if ($line -match '^\S') { break }  # dedented → left the agent: block
            if (-not $AgentName     -and $line -match '^\s+name:\s*(\S+)')          { $AgentName     = $matches[1] }
            if (-not $ResourceGroup -and $line -match '^\s+resourceGroup:\s*(\S+)') { $ResourceGroup = $matches[1] }
        }
    }
}
if (-not $AgentName)     { Write-Err "AgentName not provided and not found in $ConfigFile"; exit 1 }
if (-not $ResourceGroup) { Write-Err "ResourceGroup not provided and not found in $ConfigFile"; exit 1 }

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " SRE Agent — Clear Incidents" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Info "Agent:          $AgentName"
Write-Info "Resource Group: $ResourceGroup"

# ── Resolve agent endpoint (control plane) ───────────────────────────────────
$agentId = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $AgentName --query id -o tsv 2>$null
if (-not $agentId) { Write-Err "Agent '$AgentName' not found in '$ResourceGroup'."; exit 1 }
$endpoint = az resource show --ids $agentId --query "properties.agentEndpoint" -o tsv 2>$null
if (-not $endpoint) { Write-Err "Could not resolve agentEndpoint for '$AgentName'."; exit 1 }
Write-Info "Endpoint:       $endpoint"

# ── Data-plane token ─────────────────────────────────────────────────────────
$token = az account get-access-token --resource $DataPlaneResource --query accessToken -o tsv 2>$null
if (-not $token) { Write-Err "Failed to acquire data-plane token for $DataPlaneResource (run 'az login')."; exit 1 }
$headers = @{ Authorization = "Bearer $token"; Accept = "application/json" }

# ── List threads ─────────────────────────────────────────────────────────────
try {
    $threads = (Invoke-RestMethod -Uri "$endpoint/api/v1/threads" -Headers $headers -Method Get).value
} catch {
    Write-Err "Failed to list threads: $($_.Exception.Message)"; exit 1
}
if (-not $threads) { Write-Ok "No threads found — nothing to delete."; exit 0 }

# ── Select targets ───────────────────────────────────────────────────────────
$targets = $threads
if ($Id.Count -gt 0) {
    $targets = $threads | Where-Object { $Id -contains $_.id }
    $missing = $Id | Where-Object { $_ -notin ($threads.id) }
    foreach ($m in $missing) { Write-Warn "Thread ID not found: $m" }
} else {
    if (-not $All) {
        # Preserve non-incident threads (e.g. the WelcomeMessage onboarding thread).
        $targets = $targets | Where-Object { $_.source -eq 'Incident' }
    }
    if ($TitleContains) { $targets = $targets | Where-Object { $_.title -and $_.title -like "*$TitleContains*" } }
    if ($Status)        { $targets = $targets | Where-Object { $_.status.incidentStatus.status -eq $Status } }
}
$targets = @($targets)

Write-Host ""
Write-Info "Matched $($targets.Count) of $($threads.Count) thread(s):"
foreach ($t in $targets) {
    $st = if ($t.status.incidentStatus.status) { $t.status.incidentStatus.status } else { '(onboarding)' }
    Write-Host ("  - {0}  [{1}]  {2}" -f $t.id, $st, $t.title) -ForegroundColor Gray
}
if ($targets.Count -eq 0) { Write-Ok "Nothing matches the given filters."; exit 0 }
if ($ListOnly) { Write-Info "ListOnly specified — not deleting."; exit 0 }

# ── Confirm ──────────────────────────────────────────────────────────────────
if (-not $Force) {
    $ans = Read-Host "Delete these $($targets.Count) incident(s)? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Warn "Aborted."; exit 0 }
}

# ── Delete ───────────────────────────────────────────────────────────────────
$deleted = 0; $failed = 0
foreach ($t in $targets) {
    try {
        Invoke-WebRequest -Uri "$endpoint/api/v1/threads/$($t.id)" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
        Write-Ok "Deleted $($t.id)"
        $deleted++
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        Write-Err "Failed to delete $($t.id) (HTTP $code)"
        $failed++
    }
}

Write-Host ""
Write-Info "Done. Deleted $deleted, failed $failed."
if ($failed -gt 0) { exit 1 }
