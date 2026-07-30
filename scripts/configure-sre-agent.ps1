<#
.SYNOPSIS
    Reconcile the SRE Agent configuration manifest (sre-agent-config/config.yaml)
    against the live Azure SRE Agent.

.DESCRIPTION
    The Azure SRE Agent splits its configuration across two planes:

      * CONTROL plane (ARM / this deployment): the agent resource itself, its
        managed identity + RBAC, mode/access level, default model, the
        knowledge-graph "managed resources" scope, and the Application Insights /
        Azure Monitor wiring. These are set by infra/modules/sre-agent.bicep.

      * DATA plane (SRE Agent portal, https://sre.azure.com): uploaded knowledge
        files, custom agents, skills, incident response plans, and scheduled
        tasks. As of the 2025-05-01-preview API there is NO ARM/az surface for
        these (verified: no `az sre` extension; the agent `/knowledge` child
        resource returns 404). They must be applied in the portal.

    This script therefore RECONCILES + REPORTS rather than blindly applies:
      1. Parses the manifest (requires Python + PyYAML — already used in this repo).
      2. Verifies every file the manifest references actually exists on disk.
      3. Queries the live agent's control-plane state and compares what it can.
      4. Emits a precise, itemized portal checklist for the data-plane items.

    It exits non-zero if the agent is missing or any referenced file is absent, so
    it is safe to run in CI as a manifest validator.

.PARAMETER ConfigFile
    Path to the manifest. Default: sre-agent-config/config.yaml (repo-relative).

.PARAMETER AgentName
    SRE Agent resource name. Default: taken from the manifest (agent.name).

.PARAMETER ResourceGroup
    Resource group of the agent. Default: taken from the manifest (agent.resourceGroup).

.EXAMPLE
    .\scripts\configure-sre-agent.ps1
.EXAMPLE
    .\scripts\configure-sre-agent.ps1 -ConfigFile .\sre-agent-config\config.yaml
#>

[CmdletBinding()]
param(
    [string]$ConfigFile   = "$PSScriptRoot\..\sre-agent-config\config.yaml",
    [string]$AgentName    = "",
    [string]$ResourceGroup = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$issues = 0

function Write-Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Write-Miss($t) { Write-Host "  [MISS] $t" -ForegroundColor Red; $script:issues++ }
function Write-Todo($t) { Write-Host "  [TODO] $t" -ForegroundColor Yellow }
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
Write-Host " SRE Agent Configuration Reconciliation" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Info2 "Manifest:       $ConfigFile"
Write-Info2 "Agent:          $AgentName"
Write-Info2 "Resource Group: $ResourceGroup"

# ── Control plane: verify the live agent + what ARM controls ─────────────────
Write-Head "Control plane (ARM) — live agent"
$agent = $null
try {
    $agent = az resource show -g $ResourceGroup --resource-type "Microsoft.App/agents" -n $AgentName -o json 2>$null | ConvertFrom-Json
} catch { }
if (-not $agent) {
    Write-Miss "Agent '$AgentName' not found in '$ResourceGroup'. Deploy it first: scripts\deploy.ps1"
    Write-Host "`nCannot reconcile data plane without a live agent. Exiting." -ForegroundColor Red
    exit 1
}
Write-Ok "Agent exists — provisioningState=$($agent.properties.provisioningState), runningState=$($agent.properties.runningState)"
Write-Info2 "identity: $($agent.identity.type)"
Write-Info2 "mode/access: $($agent.properties.actionConfiguration.mode) / $($agent.properties.actionConfiguration.accessLevel)"
Write-Info2 "default model: $($agent.properties.defaultModel.name)"
$mr = $agent.properties.knowledgeGraphConfiguration.managedResources
Write-Info2 ("knowledge-graph managed resources: " + (($mr | Measure-Object).Count) + " scope(s)")
if ($null -eq $agent.properties.connectors) {
    Write-Info2 "connectors: (none listed on the resource; Azure Monitor is auto-connected as the incident platform)"
}
Write-Info2 "Portal: https://sre.azure.com/agent$($agent.id)"

# ── Data plane: verify referenced files exist, then emit portal checklist ────
Write-Head "Knowledge base ($($cfg.knowledge.Count) file(s)) — DATA PLANE (portal upload)"
foreach ($k in $cfg.knowledge) {
    $p = Join-Path $repoRoot $k
    if (Test-Path $p) { Write-Ok $k } else { Write-Miss "$k (referenced by manifest, not found on disk)" }
}

Write-Head "Custom agents ($($cfg.customAgents.Count)) — DATA PLANE"
foreach ($a in $cfg.customAgents) {
    $p = Join-Path $repoRoot $a.definitionFile
    if (Test-Path $p) { Write-Ok "$($a.name)  ($($a.definitionFile))" } else { Write-Miss "$($a.name): $($a.definitionFile) not found" }
}

Write-Head "Skills ($($cfg.skills.Count)) — DATA PLANE"
foreach ($s in $cfg.skills) {
    $p = Join-Path $repoRoot $s.directory
    if (Test-Path $p) { Write-Ok "$($s.name)  ($($s.directory))" } else { Write-Miss "$($s.name): $($s.directory) not found" }
}

Write-Head "Response plans ($($cfg.responsePlans.Count)) — DATA PLANE"
foreach ($r in $cfg.responsePlans) {
    Write-Todo "$($r.name)  [sev: $($r.severity -join ',')  agent: $($r.customAgent)  autonomy: $($r.autonomy)  titleContains: '$($r.titleContains)']"
}

Write-Head "Scheduled tasks ($($cfg.scheduledTasks.Count)) — DATA PLANE"
foreach ($t in $cfg.scheduledTasks) {
    Write-Todo "$($t.name)  [schedule: $($t.schedule)  autonomy: $($t.autonomy)]"
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Head "Summary"
if ($issues -gt 0) {
    Write-Host "  $issues manifest issue(s) found (missing files or agent). Fix before configuring the portal." -ForegroundColor Red
} else {
    Write-Ok "Manifest is internally consistent — all referenced files exist and the agent is live."
}
Write-Host @"

  NEXT STEPS (data plane — perform in the SRE Agent portal):
    1. Open the portal:  https://sre.azure.com/agent$($agent.id)
    2. Knowledge  -> upload the $($cfg.knowledge.Count) file(s) listed above (from $repoRoot).
    3. Agents     -> create the $($cfg.customAgents.Count) custom agent(s) from their definition YAML.
    4. Skills     -> add the $($cfg.skills.Count) skill folder(s).
    5. Response plans / Scheduled tasks -> create per the manifest rows above.

  WHY manual: the 2025-05-01-preview control-plane API exposes no ARM/az surface
  for these data-plane objects (no 'az sre' extension; agent '/knowledge' child
  returns 404). Re-run this script any time to re-validate the manifest.
"@ -ForegroundColor Gray

if ($issues -gt 0) { exit 2 } else { exit 0 }
