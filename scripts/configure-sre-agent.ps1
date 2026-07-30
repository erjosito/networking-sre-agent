<#
.SYNOPSIS
    Configure the Azure SRE Agent from the manifest (sre-agent-config/config.yaml):
    Azure Monitor incident integration + knowledge-graph scope (control plane) and
    knowledge-base upload (data plane). Reports remaining portal-only items.

.DESCRIPTION
    The Azure SRE Agent splits its configuration across two planes, and BOTH are now
    programmatically reachable:

      * CONTROL plane (ARM, api-version 2026-01-01 — GA):
          - incidentManagementConfiguration.type = AzMonitor  (connects Azure Monitor
            as the incident source; alerts from `managedResources` flow in automatically
            via the agent's managed identity — no credentials needed).
          - knowledgeGraphConfiguration.managedResources = [ <resource group id> ]
            (scopes alert/resource discovery). Existing `identity` is preserved.
        Applied here with `az rest` PATCH.

      * DATA plane (agent endpoint https://<name>.<region>.azuresre.ai,
        token audience https://azuresre.dev):
          - Knowledge upload: POST /api/v1/agentmemory/upload  (multipart/form-data,
            form field name `files`, repeatable; <=16MB/file, <=100MB total).
          - Status:  GET /api/v1/agentmemory/status
          - Indexer: GET /api/v1/agentmemory/indexer-status  (documentsProcessed/Failed).
        Applied here with curl.exe.

    Custom agents, skills, incident response plans and scheduled tasks do NOT yet have a
    published/stable programmatic envelope; they are reported as a portal checklist.

    Run modes:
      * default (report):  validate the manifest, show live agent state, print what WOULD
        change and the portal checklist. Read-only. Safe for CI.
      * -Apply:            apply the control-plane PATCH and upload the knowledge files.

.PARAMETER ConfigFile
    Path to the manifest. Default: sre-agent-config/config.yaml (repo-relative).

.PARAMETER AgentName
    SRE Agent resource name. Default: taken from the manifest (agent.name).

.PARAMETER ResourceGroup
    Resource group of the agent. Default: taken from the manifest (agent.resourceGroup).

.PARAMETER ManagedResourceGroupIds
    ARM resource-group IDs to set as the knowledge-graph managed-resources scope.
    Default: the agent's own resource group.

.PARAMETER IncidentPlatform
    Incident management platform type. Default: AzMonitor. (Only AzMonitor is credential-free.)

.PARAMETER Apply
    Actually apply changes. Without it the script only reports (read-only).

.PARAMETER SkipControlPlane
    In -Apply mode, skip the ARM PATCH (only upload knowledge).

.PARAMETER SkipKnowledge
    In -Apply mode, skip the knowledge upload (only PATCH control plane).

.EXAMPLE
    .\scripts\configure-sre-agent.ps1              # report only (read-only)
.EXAMPLE
    .\scripts\configure-sre-agent.ps1 -Apply       # apply AzMonitor + scope + upload knowledge
#>

[CmdletBinding()]
param(
    [string]$ConfigFile   = "$PSScriptRoot\..\sre-agent-config\config.yaml",
    [string]$AgentName    = "",
    [string]$ResourceGroup = "",
    [string[]]$ManagedResourceGroupIds = @(),
    [ValidateSet("AzMonitor","None")]
    [string]$IncidentPlatform = "AzMonitor",
    [switch]$Apply,
    [switch]$SkipControlPlane,
    [switch]$SkipKnowledge
)

$ErrorActionPreference = "Stop"
# Keep lenient property access even when a caller (e.g. deploy.ps1) has set
# Set-StrictMode -Version Latest — this script probes optional agent properties.
Set-StrictMode -Version 1.0
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ApiVersion = "2026-01-01"
$DataPlaneResource = "https://azuresre.dev"
$issues = 0

function Write-Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Write-Miss($t) { Write-Host "  [MISS] $t" -ForegroundColor Red; $script:issues++ }
function Write-Todo($t) { Write-Host "  [TODO] $t" -ForegroundColor Yellow }
function Write-Chg($t)  { Write-Host "  [CHNG] $t" -ForegroundColor Magenta }
function Write-Info2($t){ Write-Host "  $t" -ForegroundColor Gray }

# ── Parse the manifest (YAML → JSON via PyYAML) ──────────────────────────────
if (-not (Test-Path $ConfigFile)) { Write-Host "ERROR: manifest not found: $ConfigFile" -ForegroundColor Red; exit 1 }
$ConfigFile = (Resolve-Path $ConfigFile).Path

$py = @"
import json, sys, yaml
with open(r'''$ConfigFile''', 'r', encoding='utf-8') as f:
    print(json.dumps(yaml.safe_load(f)))
"@
try {
    $json = $py | python -
    $cfg  = $json | ConvertFrom-Json
} catch {
    Write-Host "ERROR: failed to parse manifest. Requires Python + PyYAML (pip install pyyaml)." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

if (-not $AgentName)     { $AgentName     = $cfg.agent.name }
if (-not $ResourceGroup) { $ResourceGroup = $cfg.agent.resourceGroup }

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " SRE Agent Configuration ($(if($Apply){'APPLY'}else{'report-only'}))" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Info2 "Manifest:       $ConfigFile"
Write-Info2 "Agent:          $AgentName"
Write-Info2 "Resource Group: $ResourceGroup"
Write-Info2 "ARM api-version:$ApiVersion"

# ── Resolve the live agent (control plane, GA API) ───────────────────────────
Write-Head "Control plane (ARM $ApiVersion) — live agent"
$agentId = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $AgentName --query id -o tsv 2>$null
if (-not $agentId) {
    Write-Miss "Agent '$AgentName' not found in '$ResourceGroup'. Deploy it first: scripts\deploy.ps1"
    Write-Host "`nCannot configure without a live agent. Exiting." -ForegroundColor Red
    exit 1
}
$armUrl = "https://management.azure.com$($agentId)?api-version=$ApiVersion"
$agent  = az rest --method get --url $armUrl -o json 2>$null | ConvertFrom-Json
if (-not $agent) { Write-Miss "Failed to GET agent via $ApiVersion."; exit 1 }

$props = $agent.properties
Write-Ok "Agent exists — provisioningState=$($props.provisioningState), runningState=$($props.runningState)"
Write-Info2 "identity:       $($agent.identity.type)"
Write-Info2 "mode/access:    $($props.actionConfiguration.mode) / $($props.actionConfiguration.accessLevel)"
$curIncident = $props.incidentManagementConfiguration
$curScope    = @($props.knowledgeGraphConfiguration.managedResources)
$kgIdentity  = $props.knowledgeGraphConfiguration.identity
Write-Info2 "incident type:  $(if($curIncident){$curIncident.type}else{'(none)'})"
Write-Info2 ("managed scope:  " + ($(if($curScope.Count){$curScope -join ', '}else{'(none)'})))
$endpoint = $props.agentEndpoint
Write-Info2 "endpoint:       $endpoint"

# Desired managed-resource scope: default to the agent's own RG.
if (-not $ManagedResourceGroupIds -or $ManagedResourceGroupIds.Count -eq 0) {
    $subId = ($agentId -split '/')[2]
    $ManagedResourceGroupIds = @("/subscriptions/$subId/resourceGroups/$ResourceGroup")
}

# Determine drift.
$incidentDrift = ($null -eq $curIncident) -or ($curIncident.type -ne $IncidentPlatform)
$scopeDrift    = (@(Compare-Object -ReferenceObject $curScope -DifferenceObject $ManagedResourceGroupIds).Count -ne 0)

if ($incidentDrift) { Write-Chg "incident platform: '$(if($curIncident){$curIncident.type}else{'none'})' -> '$IncidentPlatform'" }
                else { Write-Ok  "incident platform already '$IncidentPlatform'" }
if ($scopeDrift)    { Write-Chg "managed scope -> $($ManagedResourceGroupIds -join ', ')" }
                else { Write-Ok  "managed scope already correct" }

if ($Apply -and -not $SkipControlPlane -and ($incidentDrift -or $scopeDrift)) {
    Write-Head "Applying control-plane PATCH"
    $bodyObj = @{
        properties = @{
            incidentManagementConfiguration = @{ type = $IncidentPlatform }
            knowledgeGraphConfiguration      = @{ managedResources = @($ManagedResourceGroupIds) }
        }
    }
    if ($kgIdentity) { $bodyObj.properties.knowledgeGraphConfiguration.identity = $kgIdentity }
    $tmp = New-TemporaryFile
    ($bodyObj | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding utf8
    az rest --method patch --url $armUrl --headers "Content-Type=application/json" --body "@$($tmp.FullName)" -o none 2>$null
    $rc = $LASTEXITCODE
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0) { Write-Miss "PATCH failed (exit $rc)." }
    else {
        $after = az rest --method get --url $armUrl -o json 2>$null | ConvertFrom-Json
        $aIncident = $after.properties.incidentManagementConfiguration.type
        $aScope    = @($after.properties.knowledgeGraphConfiguration.managedResources)
        if ($aIncident -eq $IncidentPlatform) { Write-Ok "incident platform now '$aIncident'" } else { Write-Miss "incident platform is '$aIncident'" }
        if (@(Compare-Object -ReferenceObject $aScope -DifferenceObject $ManagedResourceGroupIds).Count -eq 0) { Write-Ok "managed scope applied" } else { Write-Miss "managed scope mismatch: $($aScope -join ', ')" }
    }
} elseif (-not $Apply -and ($incidentDrift -or $scopeDrift)) {
    Write-Info2 "(report-only: re-run with -Apply to PATCH the control plane)"
}

# ── Data plane: knowledge base ───────────────────────────────────────────────
Write-Head "Knowledge base ($($cfg.knowledge.Count) file(s)) — DATA PLANE (agentmemory)"
$knowledgePaths = @()
foreach ($k in $cfg.knowledge) {
    $p = Join-Path $repoRoot $k
    if (Test-Path $p) { Write-Ok $k; $knowledgePaths += (Resolve-Path $p).Path }
    else              { Write-Miss "$k (referenced by manifest, not found on disk)" }
}

if ($Apply -and -not $SkipKnowledge -and $knowledgePaths.Count -gt 0 -and $endpoint) {
    Write-Head "Uploading knowledge to agent memory"
    $dpToken = az account get-access-token --resource $DataPlaneResource --query accessToken -o tsv 2>$null
    if (-not $dpToken) { Write-Miss "Could not acquire data-plane token ($DataPlaneResource)." }
    else {
        # Upload in one multipart request (repeatable `files` field).
        $curlArgs = @('-s','-X','POST',"$endpoint/api/v1/agentmemory/upload",'-H',"Authorization: Bearer $dpToken")
        foreach ($fp in $knowledgePaths) { $curlArgs += @('-F', "files=@$fp;type=text/markdown") }
        $resp = & curl.exe @curlArgs 2>&1 | Out-String
        Write-Info2 "upload response: $($resp.Trim())"
        if ($resp -match '"indexingTriggered"\s*:\s*true' -or $resp -match 'uploaded') {
            Write-Ok "Upload accepted; indexing triggered."
        } else {
            Write-Miss "Upload did not confirm success."
        }
        # Poll indexer until the run completes (or timeout).
        Write-Info2 "Waiting for indexer to finish..."
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 6
            $ix = curl.exe -s "$endpoint/api/v1/agentmemory/indexer-status" -H "Authorization: Bearer $dpToken" 2>$null | ConvertFrom-Json
            $st = $ix.status
        } while ($st -eq "Running" -and (Get-Date) -lt $deadline)
        $le = $ix.lastExecution
        if ($le) {
            Write-Info2 ("indexer lastExecution: status=$($le.status) processed=$($le.documentsProcessed) failed=$($le.documentsFailed)")
            if ($le.status -eq "Success" -and $le.documentsFailed -eq 0) { Write-Ok "Indexing succeeded." }
            elseif ($le.documentsFailed -gt 0) { Write-Miss "Indexer reported $($le.documentsFailed) failed document(s)." }
        }
        $stat = curl.exe -s "$endpoint/api/v1/agentmemory/status" -H "Authorization: Bearer $dpToken" 2>$null | ConvertFrom-Json
        Write-Info2 "agentmemory enabled: $($stat.enabled)"
    }
} elseif (-not $Apply -and $knowledgePaths.Count -gt 0) {
    Write-Info2 "(report-only: re-run with -Apply to upload $($knowledgePaths.Count) knowledge file(s) to agent memory)"
}

# ── Portal-only items (no stable programmatic envelope yet) ───────────────────
Write-Head "Custom agents ($($cfg.customAgents.Count)) — PORTAL"
foreach ($a in $cfg.customAgents) {
    $p = Join-Path $repoRoot $a.definitionFile
    if (Test-Path $p) { Write-Ok "$($a.name)  ($($a.definitionFile))" } else { Write-Miss "$($a.name): $($a.definitionFile) not found" }
}
Write-Head "Skills ($($cfg.skills.Count)) — PORTAL"
foreach ($s in $cfg.skills) {
    $p = Join-Path $repoRoot $s.directory
    if (Test-Path $p) { Write-Ok "$($s.name)  ($($s.directory))" } else { Write-Miss "$($s.name): $($s.directory) not found" }
}
Write-Head "Response plans ($($cfg.responsePlans.Count)) — PORTAL"
foreach ($r in $cfg.responsePlans) {
    Write-Todo "$($r.name)  [sev: $($r.severity -join ',')  agent: $($r.customAgent)  autonomy: $($r.autonomy)  titleContains: '$($r.titleContains)']"
}
Write-Head "Scheduled tasks ($($cfg.scheduledTasks.Count)) — PORTAL"
foreach ($t in $cfg.scheduledTasks) {
    Write-Todo "$($t.name)  [schedule: $($t.schedule)  autonomy: $($t.autonomy)]"
}

# ── Working-agent readiness (detect → investigate → root-cause → fix) ─────────
# These are the prerequisites that, if missing, silently break the incident loop.
# The agent detects incidents by SCANNING the Azure Monitor Alerts API every ~1 min
# with its managed identity (no action-group targeting needed) — see
# https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts
Write-Head "Working-agent readiness"
$subId = ($agentId -split '/')[2]
$uami  = $props.actionConfiguration.identity
$prin  = $null
if ($uami) { $prin = az identity show --ids $uami --query principalId -o tsv 2>$null }

# DETECT 1/3 — incident platform connected
if ($curIncident -and $curIncident.type -eq $IncidentPlatform) {
    Write-Ok "Detect: incident platform = $IncidentPlatform (control plane set)"
} else {
    Write-Miss "Detect: incident platform not set to $IncidentPlatform — re-run with -Apply"
}
# DETECT 2/3 — Monitoring Contributor on the SUBSCRIPTION (required to scan alerts)
if ($prin) {
    $mc = az role assignment list --assignee $prin --scope "/subscriptions/$subId" --include-inherited --query "[?roleDefinitionName=='Monitoring Contributor'] | [0].id" -o tsv 2>$null
    if ($mc) { Write-Ok "Detect: identity has 'Monitoring Contributor' on the subscription" }
    else     { Write-Miss "Detect: identity MISSING 'Monitoring Contributor' on the subscription — alerts will NOT be scanned. Deploy modules/sre-agent-sub-roles.bicep" }
} else { Write-Info2 "Detect: could not resolve the managed-identity principal to check the subscription role." }
# DETECT 3/3 — alert rules exist and are enabled (parse JSON in PS to avoid JMESPath quoting issues)
$alertsJson = az monitor metrics alert list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
$alertNum = @($alertsJson | Where-Object { $_.enabled }).Count
if ($alertNum -gt 0) { Write-Ok "Detect: $alertNum enabled metric alert rule(s) in $ResourceGroup" }
else { Write-Miss "Detect: no enabled alert rules in $ResourceGroup — nothing will fire. Deploy modules/alerts.bicep" }

# INVESTIGATE — read access to logs/metrics + ability to run commands
if ($prin) {
    $invRoles = az role assignment list --assignee $prin --all --query "[?roleDefinitionName=='Reader' || roleDefinitionName=='Log Analytics Reader' || roleDefinitionName=='Contributor' || roleDefinitionName=='Network Contributor'].roleDefinitionName" -o tsv 2>$null
    $invSet = @($invRoles) -join ', '
    if ($invRoles -match 'Reader') { Write-Ok "Investigate: read RBAC present ($invSet)" }
    else { Write-Miss "Investigate: identity lacks Reader/Log Analytics Reader — cannot query telemetry" }
}
Write-Info2 "Investigate: knowledge base — $($cfg.knowledge.Count) file(s); run with -Apply to (re)upload+index."

# ROOT-CAUSE / FIX — autonomy + write access
$mode = $props.actionConfiguration.mode
$acc  = $props.actionConfiguration.accessLevel
if ($acc -eq 'High') { Write-Ok "Fix: accessLevel=High (Contributor) — agent CAN remediate" }
else { Write-Todo "Fix: accessLevel=$acc — agent can investigate but not change resources (set accessLevel=High to remediate)" }
if ($mode -eq 'Autonomous') { Write-Ok "Fix: mode=Autonomous — agent applies fixes without approval" }
else { Write-Todo "Fix: mode=$mode — agent PROPOSES fixes and waits for approval (set mode=Autonomous for hands-off remediation)" }

Write-Host @"

  REQUIRED PORTAL STEP for a closed loop — Incident response plan(s):
    Without at least one response plan the agent will NOT auto-act on incidents.
    In https://sre.azure.com (Builder > Incident response plans) create a plan that
    routes the severities you care about to a custom agent with the chosen autonomy.
    Manifest declares $($cfg.responsePlans.Count): $((($cfg.responsePlans | ForEach-Object { $_.name }) -join ', ')).
    Docs: https://learn.microsoft.com/azure/sre-agent/incident-response-plans
  OPTIONAL PORTAL STEPS (improve investigation quality):
    * Custom (sub)agents — $($cfg.customAgents.Count) declared (network-expert, connectivity-triage).
    * Connectors (data sources, e.g. Azure Monitor logs) — Builder > Connectors.
    * Confirm 'Builder > Incident platform' shows Azure Monitor connected + Save.
"@ -ForegroundColor Gray

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Head "Summary"
if ($issues -gt 0) {
    Write-Host "  $issues issue(s) found." -ForegroundColor Red
} elseif ($Apply) {
    Write-Ok "Applied: Azure Monitor incident integration + managed scope + knowledge upload."
} else {
    Write-Ok "Manifest is consistent. Re-run with -Apply to configure the agent."
}
Write-Host @"

  APPLIED PROGRAMMATICALLY (with -Apply):
    * Control plane (ARM $ApiVersion): incidentManagementConfiguration.type=$IncidentPlatform,
      knowledgeGraphConfiguration.managedResources=<resource group>.
    * Data plane (agentmemory): uploaded + indexed the $($cfg.knowledge.Count) knowledge file(s).

  STILL PORTAL (no stable programmatic envelope): custom agents, skills, response plans,
  scheduled tasks. Portal: https://sre.azure.com/agent$($agent.id)
"@ -ForegroundColor Gray

if ($issues -gt 0) { exit 2 } else { exit 0 }
