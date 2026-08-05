<#
.SYNOPSIS
    Live-tail Azure SRE Agent incidents for a demo screen.

.DESCRIPTION
    Polls the agent data plane and prints incident activity as it happens:
    waits for a NEW incident to open (optionally filtered by title), then streams
    each new message the agent posts — its plan, the diagnostics it runs, and its
    root-cause / remediation conclusion — until the investigation wraps up or a
    timeout is reached. Designed to be watched on-camera next to the portal.

    Resolves the agent name/RG from sre-agent-config/config.yaml (like the other
    scripts). Read-only against the agent; injects/reverts nothing.

.PARAMETER TitleContains
    Only follow incidents whose title contains this substring (e.g. 'clab').
    Empty (default) follows the next incident of any title.

.PARAMETER ThreadId
    Follow a specific incident thread id instead of waiting for a new one.

.PARAMETER SinceUtc
    Only consider incidents created at/after this UTC time (default: now). Lets the
    demo ignore pre-existing incidents and attach to the one your fault triggers.

.PARAMETER TimeoutMinutes
    Give up waiting/streaming after this many minutes (default 30).

.PARAMETER PollSeconds
    Poll interval (default 15).

.PARAMETER MaxChars
    Truncate each printed message body to this many characters (default 700).

.EXAMPLE
    .\watch-incidents.ps1 -TitleContains clab
    .\watch-incidents.ps1 -ThreadId 5a456a03-... -TimeoutMinutes 45
#>

[CmdletBinding()]
param(
    [string]$ConfigFile     = "$PSScriptRoot\..\sre-agent-config\config.yaml",
    [string]$AgentName      = "",
    [string]$ResourceGroup  = "",
    [string]$TitleContains  = "",
    [string]$ThreadId       = "",
    [datetime]$SinceUtc     = [datetime]::UtcNow,
    [int]$TimeoutMinutes    = 30,
    [int]$PollSeconds       = 15,
    [int]$MaxChars          = 700
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
            if ($line -match '^\S') { break }
            if (-not $AgentName     -and $line -match '^\s+name:\s*(\S+)')          { $AgentName     = $matches[1] }
            if (-not $ResourceGroup -and $line -match '^\s+resourceGroup:\s*(\S+)') { $ResourceGroup = $matches[1] }
        }
    }
}
if (-not $AgentName)     { Write-Err "AgentName not resolved (config: $ConfigFile)"; exit 1 }
if (-not $ResourceGroup) { Write-Err "ResourceGroup not resolved (config: $ConfigFile)"; exit 1 }

$endpoint = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $AgentName --query "properties.agentEndpoint" -o tsv 2>$null
if (-not $endpoint) { Write-Err "Could not resolve agentEndpoint for '$AgentName'."; exit 1 }

# ── Token handling (refresh on demand; tokens ~60min but watch may run long) ─
$script:Token = $null
$script:TokenAt = [datetime]::MinValue
function Get-DpToken {
    if (-not $script:Token -or ([datetime]::UtcNow - $script:TokenAt).TotalMinutes -gt 40) {
        $script:Token = az account get-access-token --resource $DataPlaneResource --query accessToken -o tsv 2>$null
        $script:TokenAt = [datetime]::UtcNow
        if (-not $script:Token) { throw "Failed to acquire data-plane token (run 'az login')." }
    }
    return $script:Token
}
function Invoke-Api {
    param([string]$Path)
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $h = @{ Authorization = "Bearer $(Get-DpToken)"; Accept = "application/json" }
            return Invoke-RestMethod -Uri "$endpoint$Path" -Headers $h -Method Get
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($code -eq 401 -and $try -eq 0) { $script:Token = $null; continue }  # refresh + retry once
            throw
        }
    }
}

function Format-Body {
    param([string]$Text)
    if (-not $Text) { return "" }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $MaxChars) { $t = $t.Substring(0, $MaxChars) + " …[truncated]" }
    return $t
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " SRE Agent — Live Incident Watch" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Info "Endpoint:  $endpoint"
Write-Info "Since:     $($SinceUtc.ToString('u'))  (UTC)"
if ($TitleContains) { Write-Info "Filter:    title contains '$TitleContains'" }
if ($ThreadId)      { Write-Info "Thread:    $ThreadId" }
Write-Info "Timeout:   $TimeoutMinutes min   Poll: every $PollSeconds s"
Write-Host ""

# ── Phase 1: acquire the target incident ─────────────────────────────────────
if (-not $ThreadId) {
    Write-Info "Waiting for a new incident to open…"
    while (-not $ThreadId) {
        if ((Get-Date) -gt $deadline) { Write-Warn "Timed out waiting for an incident to open."; exit 2 }
        try {
            $threads = (Invoke-Api "/api/v1/threads").value
        } catch { Write-Warn "threads poll failed: $($_.Exception.Message)"; Start-Sleep $PollSeconds; continue }

        $cand = $threads |
            Where-Object { $_.source -eq 'Incident' } |
            Where-Object { -not $TitleContains -or ($_.title -like "*$TitleContains*") } |
            Where-Object { $_.createdTimestamp -and ([datetime]$_.createdTimestamp).ToUniversalTime() -ge $SinceUtc.AddSeconds(-30) } |
            Sort-Object { [datetime]$_.createdTimestamp } -Descending |
            Select-Object -First 1

        if ($cand) {
            $ThreadId = $cand.id
            Write-Host ""
            Write-Ok "Incident opened: $($cand.title)"
            Write-Info "Thread id: $ThreadId"
            $det = try { Invoke-Api "/api/v1/threads/$ThreadId" } catch { $null }
            if ($det) { Write-Info "Mode: $($det.agentMode)   Status: $($det.status.incidentStatus.status)" }
            Write-Host ""
        } else {
            Write-Host "." -NoNewline -ForegroundColor DarkGray
            Start-Sleep $PollSeconds
        }
    }
}

# ── Phase 2: stream messages until the investigation wraps up ────────────────
Write-Info "Streaming investigation messages (Ctrl+C to stop)…"
Write-Host ""
$printed = 0
$done = $false
while (-not $done) {
    if ((Get-Date) -gt $deadline) { Write-Warn "Watch timeout reached ($TimeoutMinutes min)."; break }

    try {
        $msgs = (Invoke-Api "/api/v1/threads/$ThreadId/messages").value
    } catch { Write-Warn "messages poll failed: $($_.Exception.Message)"; Start-Sleep $PollSeconds; continue }

    if ($msgs.Count -gt $printed) {
        foreach ($m in $msgs[$printed..($msgs.Count - 1)]) {
            $role = $m.author.role
            $ts   = if ($m.timeStamp) { ([datetime]$m.timeStamp).ToLocalTime().ToString('HH:mm:ss') } else { '--:--:--' }
            $color = switch ($role) { 'SREAgent' { 'Green' } 'User' { 'Gray' } default { 'White' } }
            Write-Host ("┌─ [{0}] {1}" -f $ts, $role) -ForegroundColor $color

            # Surface tool/command activity explicitly (great on camera).
            $tags = @()
            if ($m.azCliExecution)     { $tags += 'az CLI' }
            if ($m.terminalResult)     { $tags += 'terminal' }
            if ($m.pythonExecutionResult) { $tags += 'python' }
            if ($m.knowledgeGraphSearchResult) { $tags += 'knowledge-graph' }
            if ($m.memorySearchResult) { $tags += 'knowledge/memory' }
            if ($m.grepSearchResult -or $m.readFileResult) { $tags += 'files/skills' }
            if ($m.todoInfo)           { $tags += 'plan/todos' }
            if ($tags.Count) { Write-Host ("│  ⚙ used: {0}" -f ($tags -join ', ')) -ForegroundColor DarkCyan }

            $body = Format-Body $m.text
            if ($body) { Write-Host ("│  {0}" -f $body) -ForegroundColor $color }
            Write-Host "└─" -ForegroundColor $color
            Write-Host ""

            # Completion heuristics: the agent posts a "Session Insights" trajectory
            # summary when it wraps, or the incident flips to resolved.
            if ($m.text -and ($m.text -match '(?i)Session Insights' -or $m.text -match '(?i)^#+\s*Root Cause')) {
                $done = $true
            }
        }
        $printed = $msgs.Count
    }

    if (-not $done) {
        # Also stop if the incident status itself flips to resolved.
        try {
            $st = (Invoke-Api "/api/v1/threads/$ThreadId").status.incidentStatus.status
            if ($st -eq 'resolved') { Write-Ok "Incident status → resolved."; $done = $true }
        } catch { }
    }
    if (-not $done) { Start-Sleep $PollSeconds }
}

Write-Host ""
Write-Ok "Watch complete. Full detail: portal → SRE Agent → incident thread $ThreadId"
