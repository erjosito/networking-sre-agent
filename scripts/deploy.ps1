<#
.SYNOPSIS
    Deploy the Azure Networking SRE Agent test environment.

.DESCRIPTION
    Creates a resource group and deploys the Bicep infrastructure template
    for the hub-spoke networking lab with VPN gateways, NVAs, and spoke VMs.

.PARAMETER ResourceGroup
    Name of the Azure resource group (default: netsre-rg).

.PARAMETER Location
    Azure region for deployment (default: eastus2).

.PARAMETER Prefix
    Prefix for all resource names (default: netsre).

.PARAMETER SshKeyPath
    Path to SSH public key file (default: ~/.ssh/id_rsa.pub).

.PARAMETER AdminUsername
    VM administrator username (default: azureuser).

.PARAMETER AdminPassword
    VM administrator password (used if no SSH key is available).

.PARAMETER VpnSharedKey
    Shared key for all site-to-site VPN connections (default: TestVpnKey2025!).

.PARAMETER DeploySreAgent
    Whether to deploy the Azure SRE Agent (default: $true). Requires an Entra
    sponsor group (see -SreAgentSponsorGroupId).

.PARAMETER SreAgentSponsorGroupId
    Object ID of the Microsoft Entra group whose members can manage the SRE Agent.
    Required when -DeploySreAgent is $true. If omitted, the script auto-discovers a
    group named 'SRE'. See README > Azure SRE Agent Setup to create one.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -ResourceGroup "mylab-rg" -Location "westus2" -Prefix "mylab"
    .\deploy.ps1 -AdminPassword (ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force)
    .\deploy.ps1 -DeploySreAgent $false
    .\deploy.ps1 -SreAgentSponsorGroupId "a739e015-b648-455b-aa66-bade65761e3a"
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP ?? "netsre-rg",
    [string]$Location      = $env:LOCATION ?? "eastus2",
    [string]$Prefix        = $env:PREFIX ?? "netsre",
    [string]$SshKeyPath    = $env:SSH_KEY_PATH ?? "$HOME/.ssh/id_rsa.pub",
    [string]$AdminUsername  = $env:ADMIN_USERNAME ?? "azureuser",
    [SecureString]$AdminPassword,
    [string]$VpnSharedKey  = $env:VPN_SHARED_KEY ?? "TestVpnKey2025!",
    [bool]$DeploySreAgent  = $true,
    [string]$SreAgentSponsorGroupId = $env:SRE_AGENT_SPONSOR_GROUP_ID ?? ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info  { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Green }
function Write-Warn  { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err   { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Resolve paths
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoDir    = Split-Path -Parent $ScriptDir
$TemplateFile = Join-Path $RepoDir "infra" "main.bicep"

# ─── Pre-flight checks ───────────────────────────────────────────────────────

Write-Info "Running pre-flight checks..."

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI (az) is not installed. See https://aka.ms/install-azure-cli"
    exit 1
}

try {
    az account show 2>&1 | Out-Null
} catch {
    Write-Err "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}

if (-not (Test-Path $TemplateFile)) {
    Write-Err "Bicep template not found at $TemplateFile"
    exit 1
}

# Determine authentication method
if (Test-Path $SshKeyPath) {
    $SshKeyData = (Get-Content $SshKeyPath -Raw).Trim()
    Write-Info "Using SSH key: $SshKeyPath"
} else {
    Write-Err "No SSH key found at $SshKeyPath."
    Write-Err "Generate a key with: ssh-keygen -t rsa -b 4096"
    exit 1
}

# Always require a password for serial console access
if (-not $AdminPassword) {
    $AdminPassword = Read-Host "Enter admin password (for serial console access)" -AsSecureString
}
$PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))
if ([string]::IsNullOrEmpty($PlainPassword)) {
    Write-Err "A password is required for serial console access."
    exit 1
}

# Resolve the SRE Agent sponsor group (a Microsoft Entra group whose members can
# manage the agent). If not supplied, try to auto-discover a group named 'SRE'.
if ($DeploySreAgent -and [string]::IsNullOrEmpty($SreAgentSponsorGroupId)) {
    Write-Info "Resolving SRE Agent sponsor group (Entra group named 'SRE')..."
    $SreAgentSponsorGroupId = az ad group show --group "SRE" --query id -o tsv 2>$null
    if ([string]::IsNullOrEmpty($SreAgentSponsorGroupId)) {
        Write-Err "deploySreAgent is true but no sponsor group was found."
        Write-Err "Create one (see README > Azure SRE Agent Setup) and pass -SreAgentSponsorGroupId <id>,"
        Write-Err "or deploy without the agent: -DeploySreAgent `$false"
        exit 1
    }
    Write-Info "Sponsor group 'SRE': $SreAgentSponsorGroupId"
}

$Subscription = az account show --query name -o tsv
Write-Info "Subscription  : $Subscription"
Write-Info "Resource Group : $ResourceGroup"
Write-Info "Location       : $Location"
Write-Info "Prefix         : $Prefix"
Write-Host ""
Write-Warn "⏱  This deployment takes approximately 30-45 minutes."
Write-Warn "   VPN Gateways are the slowest component (~25-30 min each)."
Write-Host ""

# ─── Deploy ──────────────────────────────────────────────────────────────────

Write-Info "Creating resource group '$ResourceGroup' in '$Location'..."
az group create `
    --name $ResourceGroup `
    --location $Location `
    --output none

Write-Info "Starting Bicep deployment (this will take a while)..."
$DeployStart = Get-Date
$DeploymentName = "netsre-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Build a parameters FILE rather than inline `key=value` pairs. Inline parameters
# break on values that contain spaces or `=` (most notably the SSH public key),
# which manifests as a silent multi-minute hang or an "Unable to parse parameter"
# error with the deployment never registering in ARM. A parameters file avoids
# all quoting/whitespace issues.
$ParamsFile = Join-Path ([System.IO.Path]::GetTempPath()) "netsre-deploy-params-$DeploymentName.json"
$ParamsObj = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        prefix         = @{ value = $Prefix }
        location       = @{ value = $Location }
        adminUsername  = @{ value = $AdminUsername }
        adminPublicKey = @{ value = $SshKeyData }
        adminPassword  = @{ value = $PlainPassword }
        vpnSharedKey   = @{ value = $VpnSharedKey }
        deploySreAgent = @{ value = $DeploySreAgent }
    }
}
if ($DeploySreAgent) {
    $ParamsObj.parameters.sreAgentSponsorGroupId = @{ value = $SreAgentSponsorGroupId }
}
$ParamsObj | ConvertTo-Json -Depth 10 | Out-File $ParamsFile -Encoding utf8

try {
    az deployment group create `
        --resource-group $ResourceGroup `
        --template-file $TemplateFile `
        --parameters "@$ParamsFile" `
        --name $DeploymentName `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Deployment failed."
        exit 1
    }
} finally {
    Remove-Item $ParamsFile -ErrorAction SilentlyContinue
}

$DeployEnd = Get-Date
$DeployDuration = [math]::Round(($DeployEnd - $DeployStart).TotalMinutes)

Write-Info "Deployment completed in ~$DeployDuration minutes."

# ─── Post-deployment: Enable static website and upload index.html ────────────
# The deployment script (Microsoft.Resources/deploymentScripts) cannot be used
# because subscription policies block key-based auth on storage accounts, which
# the deployment scripts service requires internally for its own artifact storage.

Write-Host ""
Write-Info "Configuring static website for Private Endpoint health probes..."

$saName = az storage account list -g $ResourceGroup `
    --query "[?starts_with(name,'${Prefix}web') || starts_with(name,'$($Prefix.Replace('-',''))web')].name | [0]" -o tsv 2>$null

if ($saName) {
    Write-Info "Storage account: $saName"

    # Enable static website (data-plane, uses caller's Entra ID via --auth-mode login)
    az storage blob service-properties update `
        --account-name $saName `
        --static-website `
        --index-document index.html `
        --404-document index.html `
        --auth-mode login `
        --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Info "Static website enabled."
    } else {
        Write-Warn "Could not enable static website. You may need Storage Blob Data Contributor role."
    }

    # Upload index.html
    $htmlFile = Join-Path $env:TEMP "sre-index.html"
    Set-Content -Path $htmlFile -Value '<html><head><title>SRE Health Probe</title></head><body><h1>OK</h1><p>Private Endpoint connectivity verified.</p></body></html>' -NoNewline
    az storage blob upload `
        --account-name $saName `
        --container-name '$web' `
        --name index.html `
        --file $htmlFile `
        --overwrite `
        --auth-mode login `
        --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Info "index.html uploaded to static website."
    } else {
        Write-Warn "Could not upload index.html. You may need Storage Blob Data Contributor role."
    }
    Remove-Item $htmlFile -ErrorAction SilentlyContinue
} else {
    Write-Warn "No storage account found for static website. Private Endpoint HTTP probes may fail."
}

# ─── Print outputs ───────────────────────────────────────────────────────────

Write-Host ""
Write-Info "=== Deployment Outputs ==="
az deployment group show `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --query properties.outputs `
    --output table 2>$null

Write-Host ""
Write-Info "=== Quick Reference ==="
Write-Host "  Resource Group : $ResourceGroup"
Write-Host "  Location       : $Location"
Write-Host "  Admin User     : $AdminUsername"
Write-Host ""
Write-Info "Next steps:"
Write-Host "  1. Verify health:       .\scripts\check-health.ps1 -ResourceGroup $ResourceGroup"
Write-Host "  2. Inject a fault:      .\scripts\inject-fault.ps1 -Fault vpn-disconnect -ResourceGroup $ResourceGroup"
Write-Host "  3. Tear down when done: .\scripts\teardown.ps1 -ResourceGroup $ResourceGroup"
Write-Host ""
Write-Info "Done! 🚀"
