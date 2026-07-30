<#
.SYNOPSIS
    Deploy the on-premises networking extension (Stages 0-1) as optional add-ons
    on top of an existing Azure Networking SRE Agent lab.

.DESCRIPTION
    Layers device-level telemetry and an in-path simulated network device onto
    the existing on-prem VNet WITHOUT modifying the core deployment.

      Stage 'telemetry' : collector VM (rsyslog + Azure Monitor Agent + Telegraf
                          + FreeRADIUS) shipping syslog to the lab Log Analytics
                          workspace and SNMP-derived custom metrics to Azure
                          Monitor, and serving as the on-prem AAA (RADIUS) server.
      Stage 'device'    : FRR router NVA + an on-prem server target behind it
                          (UDR-forced data path) + a Connection Monitor + alerts.
                          The router authenticates operator SSH logins via RADIUS.
      Stage 'aaa'       : AAA audit pipeline — ships the FreeRADIUS auth log into
                          a custom OnPremAAA_CL table in Log Analytics (needs the
                          collector from 'telemetry').
      Stage 'all'       : telemetry + device + aaa (default).

    Requires the base lab (deploy.ps1) to already be deployed in the same RG.

.PARAMETER ResourceGroup
    Resource group of the existing lab (default: netsre-rg).

.PARAMETER Location
    Azure region (must match the lab / Network Watcher region; default: eastus2).

.PARAMETER Prefix
    Resource naming prefix of the existing lab (default: netsre).

.PARAMETER Stage
    telemetry | device | aaa | containerlab | all (default: all).

.PARAMETER AlertEmail
    Email for the on-prem alert action group (default: netops@example.com).

.PARAMETER SshKeyPath
    Path to SSH public key (default: ~/.ssh/id_rsa.pub).

.PARAMETER AdminUsername
    VM admin username (default: azureuser).

.PARAMETER AdminPassword
    VM admin password (SecureString; prompted if omitted).

.EXAMPLE
    .\deploy-onprem.ps1 -Stage all
    .\deploy-onprem.ps1 -ResourceGroup mylab-rg -Prefix mylab -Stage telemetry
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP ?? "netsre-rg",
    [string]$Location      = $env:LOCATION ?? "eastus2",
    [string]$Prefix        = $env:PREFIX ?? "netsre",
    [ValidateSet('telemetry', 'device', 'aaa', 'containerlab', 'all')]
    [string]$Stage         = "all",
    [string]$AlertEmail    = $env:ALERT_EMAIL ?? "netops@example.com",
    [string]$SshKeyPath    = $env:SSH_KEY_PATH ?? "$HOME/.ssh/id_rsa.pub",
    [string]$AdminUsername = $env:ADMIN_USERNAME ?? "azureuser",
    [SecureString]$AdminPassword,
    [string]$RadiusSharedSecret     = $env:RADIUS_SHARED_SECRET ?? "LabRadius2026!",
    [string]$RadiusOperatorPassword = $env:RADIUS_OPERATOR_PASSWORD ?? "OperPass2026!",
    [string]$RepoBranch    = $env:REPO_BRANCH ?? "onprem"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoDir     = Split-Path -Parent $ScriptDir
$ModulesDir  = Join-Path $RepoDir "infra" "modules"

# Static IPs (must live inside the on-prem default subnet 10.100.1.0/24).
$CollectorIp = "10.100.1.100"
$FrrIp       = "10.100.1.201"

# ─── Pre-flight ──────────────────────────────────────────────────────────────

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI (az) is not installed. See https://aka.ms/install-azure-cli"; exit 1
}
try { az account show 2>&1 | Out-Null } catch { Write-Err "Not logged in. Run 'az login'."; exit 1 }

# Authentication (SSH key required; password for serial console).
$AuthParams = @()
if (Test-Path $SshKeyPath) {
    $SshKeyData = (Get-Content $SshKeyPath -Raw).Trim()
    $AuthParams += "adminPublicKey=$SshKeyData"
    Write-Info "Using SSH key: $SshKeyPath"
} else {
    Write-Err "No SSH key found at $SshKeyPath. Generate one with: ssh-keygen -t rsa -b 4096"; exit 1
}
if (-not $AdminPassword) {
    $AdminPassword = Read-Host "Enter admin password (for serial console access)" -AsSecureString
}
$PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))
if ([string]::IsNullOrEmpty($PlainPassword)) { Write-Err "A password is required."; exit 1 }
$AuthParams += "adminPassword=$PlainPassword"
$AuthParams += "adminUsername=$AdminUsername"

# Resolve existing lab resources.
Write-Info "Resolving existing lab resources in '$ResourceGroup'..."
$OnpremVnetName = "$Prefix-onprem-vnet"
$DefaultSubnetId = az network vnet subnet show -g $ResourceGroup --vnet-name $OnpremVnetName -n default --query id -o tsv 2>$null
if (-not $DefaultSubnetId) { Write-Err "On-prem VNet '$OnpremVnetName' / subnet 'default' not found. Deploy the base lab first."; exit 1 }
$LawId = az monitor log-analytics workspace show -g $ResourceGroup -n "$Prefix-law" --query id -o tsv 2>$null
if (-not $LawId) { Write-Err "Log Analytics workspace '$Prefix-law' not found."; exit 1 }
Write-Info "On-prem subnet : $DefaultSubnetId"
Write-Info "Workspace      : $LawId"

# Helper: deploy a module and return its outputs as a PSObject.
function Invoke-ModuleDeploy {
    param([string]$Name, [string]$Template, [string]$Scope = $ResourceGroup, [string[]]$Parameters)
    Write-Info "Deploying module '$Name'..."
    $deployName = "$Prefix-onprem-$Name-$(Get-Date -Format 'yyyyMMddHHmmss')"
    # Build a parameters JSON file. Inline '--parameters key=value' breaks on any
    # value containing spaces or '=' (most notably the SSH public key), producing
    # a client-side parse failure that manifests as a multi-minute hang with zero
    # deployments registered in ARM. See the azure-lab skill "Known Issues".
    $paramObj = [ordered]@{}
    foreach ($p in $Parameters) {
        $idx = $p.IndexOf('=')
        $paramObj[$p.Substring(0, $idx)] = @{ value = $p.Substring($idx + 1) }
    }
    $paramFile = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $paramObj
    }
    $tmp = Join-Path $env:TEMP "$deployName.params.json"
    $paramFile | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding utf8
    $out  = az deployment group create --resource-group $Scope --template-file $Template `
        --name $deployName --parameters "@$tmp" --query "properties.outputs" --output json
    $exit = $LASTEXITCODE
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($exit -ne 0) { Write-Err "Module '$Name' deployment failed."; exit 1 }
    return ($out | ConvertFrom-Json)
}

$doTelemetry = $Stage -in @('telemetry', 'all')
$doDevice    = $Stage -in @('device', 'all')
$doAaa       = $Stage -in @('aaa', 'all')
$doClab      = $Stage -in @('containerlab')

Write-Host ""
Write-Warn "This deploys VMs and (for 'device') a Connection Monitor. Allow several minutes."
Write-Host ""

# ─── Stage 0: telemetry ──────────────────────────────────────────────────────

if ($doTelemetry) {
    $collector = Invoke-ModuleDeploy -Name "collector" -Template (Join-Path $ModulesDir "onprem-collector.bicep") -Parameters (@(
        "location=$Location", "prefix=$Prefix",
        "subnetId=$DefaultSubnetId", "collectorPrivateIp=$CollectorIp",
        "logAnalyticsWorkspaceId=$LawId",
        "radiusSharedSecret=$RadiusSharedSecret", "radiusOperatorPassword=$RadiusOperatorPassword"
    ) + $AuthParams)
    Write-Info "Collector deployed at $CollectorIp (syslog:514, AMA -> $Prefix-law, FreeRADIUS AAA)."

    # Telemetry alerts (syslog critical, AAA auth failures, collector heartbeat
    # missing, SNMP sysUpTime reset) — these detect control-plane/audit/device
    # events that Connection Monitor cannot see.
    $null = Invoke-ModuleDeploy -Name "log-alerts" -Template (Join-Path $ModulesDir "onprem-log-alerts.bicep") -Parameters @(
        "prefix=$Prefix", "location=$Location", "alertEmail=$AlertEmail",
        "logAnalyticsWorkspaceId=$LawId", "collectorVmId=$($collector.collectorVmId.value)"
    )
    Write-Info "On-prem telemetry alerts deployed ($Prefix-onprem-ag: syslog/AAA/heartbeat/SNMP)."
}

# ─── Stage 1: in-path device + target + monitoring ───────────────────────────

if ($doDevice) {
    $null = Invoke-ModuleDeploy -Name "router" -Template (Join-Path $ModulesDir "onprem-router.bicep") -Parameters (@(
        "location=$Location", "prefix=$Prefix",
        "subnetId=$DefaultSubnetId", "frrPrivateIp=$FrrIp",
        "collectorPrivateIp=$CollectorIp",
        "radiusSharedSecret=$RadiusSharedSecret"
    ) + $AuthParams)
    Write-Info "FRR router deployed at $FrrIp."

    $lan = Invoke-ModuleDeploy -Name "lan" -Template (Join-Path $ModulesDir "onprem-lan.bicep") -Parameters (@(
        "location=$Location", "prefix=$Prefix",
        "onpremVnetName=$OnpremVnetName", "frrPrivateIp=$FrrIp",
        "collectorPrivateIp=$CollectorIp"
    ) + $AuthParams)
    $serverVmId = $lan.serverVmId.value
    $serverVmName = $lan.serverVmName.value
    $serverVmIp = $lan.serverPrivateIp.value
    Write-Info "On-prem server '$serverVmName' deployed at $serverVmIp (behind FRR)."

    # Resolve probe sources: one spoke in each hub. Both reach the on-prem
    # server via the VPN gateway and the GatewaySubnet UDR -> FRR, so they
    # genuinely transit the router (unlike the on-prem VM, which would reach
    # the LAN subnet directly via a VNet system route and bypass FRR).
    $spokeAVmName = "$Prefix-spoke11-vm"
    $spokeBVmName = "$Prefix-spoke21-vm"
    $spokeAVmId = az vm show -g $ResourceGroup -n $spokeAVmName --query id -o tsv
    $spokeAVmIp = az vm show -g $ResourceGroup -n $spokeAVmName -d --query privateIps -o tsv
    $spokeBVmId = az vm show -g $ResourceGroup -n $spokeBVmName --query id -o tsv
    $spokeBVmIp = az vm show -g $ResourceGroup -n $spokeBVmName -d --query privateIps -o tsv

    $cm = Invoke-ModuleDeploy -Name "connection-monitor" -Template (Join-Path $ModulesDir "onprem-connection-monitor.bicep") -Scope "NetworkWatcherRG" -Parameters @(
        "location=$Location", "prefix=$Prefix",
        "serverVmId=$serverVmId", "serverVmName=$serverVmName", "serverVmIp=$serverVmIp",
        "spokeAVmId=$spokeAVmId", "spokeAVmName=$spokeAVmName", "spokeAVmIp=$spokeAVmIp",
        "spokeBVmId=$spokeBVmId", "spokeBVmName=$spokeBVmName", "spokeBVmIp=$spokeBVmIp",
        "logAnalyticsWorkspaceId=$LawId"
    )
    $cmId = $cm.connectionMonitorId.value
    Write-Info "Connection Monitor deployed: $cmId"

    $null = Invoke-ModuleDeploy -Name "alerts" -Template (Join-Path $ModulesDir "onprem-alerts.bicep") -Parameters @(
        "prefix=$Prefix", "alertEmail=$AlertEmail", "connectionMonitorId=$cmId"
    )
    Write-Info "Alerts deployed ($Prefix-onprem-cm-checks-failed)."
}

# ─── Stage 2: AAA audit pipeline (RADIUS -> Log Analytics) ────────────────────

if ($doAaa) {
    $null = Invoke-ModuleDeploy -Name "aaa" -Template (Join-Path $ModulesDir "onprem-aaa.bicep") -Parameters @(
        "location=$Location", "prefix=$Prefix",
        "logAnalyticsWorkspaceId=$LawId"
    )
    Write-Info "AAA pipeline deployed (FreeRADIUS audit log -> OnPremAAA_CL in $Prefix-law)."
}

# ─── Stage A2: Containerlab high-fidelity simulation (opt-in) ─────────────────

if ($doClab) {
    $clab = Invoke-ModuleDeploy -Name "containerlab" -Template (Join-Path $ModulesDir "onprem-containerlab.bicep") -Parameters (@(
        "location=$Location", "prefix=$Prefix",
        "subnetId=$DefaultSubnetId", "collectorPrivateIp=$CollectorIp",
        "repoBranch=$RepoBranch"
    ) + $AuthParams)
    $clabIp = $clab.clabPrivateIp.value
    Write-Info "Containerlab host deployed at $clabIp (Docker + Containerlab)."
    Write-Info "Fabric auto-deploys on boot from branch '$RepoBranch' (allow a few minutes for image pulls)."

    # Connection Monitor that traverses the containerized fabric: clab-host -> r1 ->
    # eBGP -> r2 -> in-fabric server (172.31.20.10). Breaking the r1<->r2 session
    # fails this probe (control-plane fault localized to the simulated fabric).
    $clabCm = Invoke-ModuleDeploy -Name "clab-connection-monitor" -Template (Join-Path $ModulesDir "onprem-clab-connection-monitor.bicep") -Scope "NetworkWatcherRG" -Parameters @(
        "location=$Location", "prefix=$Prefix",
        "clabVmId=$($clab.clabVmId.value)", "clabVmName=$($clab.clabVmName.value)", "clabVmIp=$clabIp",
        "logAnalyticsWorkspaceId=$LawId"
    )
    Write-Info "Containerlab Connection Monitor deployed: $($clabCm.connectionMonitorId.value)"

    # Checks-failed / test-result alerts for the containerlab path so breaking the
    # r1<->r2 BGP session raises an incident the SRE Agent can act on.
    $null = Invoke-ModuleDeploy -Name "clab-alerts" -Template (Join-Path $ModulesDir "onprem-alerts.bicep") -Parameters @(
        "prefix=$Prefix", "alertEmail=$AlertEmail",
        "connectionMonitorId=$($clabCm.connectionMonitorId.value)",
        "monitorLabel=clab", "actionGroupShortName=ClabNetOps"
    )
    Write-Info "Containerlab alerts deployed ($Prefix-clab-cm-checks-failed)."
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Info "=== On-prem extension deployed (Stage: $Stage) ==="
if ($doTelemetry) {
    Write-Host "  Collector      : $CollectorIp  (Syslog table + custom metrics in $Prefix-law)"
}
if ($doDevice) {
    Write-Host "  FRR router     : $FrrIp"
    Write-Host "  On-prem server : behind FRR in the onprem-lan subnet (10.100.2.0/24)"
    Write-Host "  Detection      : breaking the FRR router fails '$Prefix-onprem-connection-monitor'"
}
if ($doClab) {
    Write-Host "  Containerlab   : $clabIp  (2x FRR + host; SSH in and run 'sudo containerlab inspect -t /opt/networking-sre-agent/infra/containerlab/onprem.clab.yml')"
    Write-Host "  Clab detection : breaking the r1<->r2 BGP session fails '$Prefix-clab-connection-monitor'"
}
Write-Host ""
Write-Info "Verify: KQL 'Syslog | where TimeGenerated > ago(15m) | take 20' in $Prefix-law"
Write-Info "Done! 🚀"
