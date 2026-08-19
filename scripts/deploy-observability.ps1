<#
.SYNOPSIS
    Deploy the optional Azure Copilot Observability Agent workload extension.

.DESCRIPTION
    Adds an OpenTelemetry-instrumented API to spoke11. The API continuously
    exercises Private Endpoint DNS/HTTPS, cross-hub HTTP, and (when deployed)
    the on-prem server. Application Insights alerts provide an application-level
    symptom that the Observability Agent can correlate with the lab's existing
    Azure Monitor, Connection Monitor, VPN, DNS, and on-prem telemetry.

    The Observability Agent and its Azure Monitor workspace are deployed in a
    region that supports autonomous operations. They can differ from the base
    lab region.

.PARAMETER AppGatewayAllowedSourceCidr
    Optional presenter public IPv4 address or CIDR. When supplied, configure the
    existing Hub1 Application Gateway for direct HTTP access after deployment.
    When omitted, no public API ingress is created.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP ?? "netsre-rg",
    [string]$Location = $env:LOCATION ?? "eastus2",
    [ValidateSet('australiaeast', 'canadacentral', 'centralus', 'eastasia', 'eastus', 'southcentralus', 'uksouth', 'westcentralus', 'westeurope')]
    [string]$ObservabilityLocation = $env:OBSERVABILITY_LOCATION ?? "canadacentral",
    [string]$Prefix = $env:PREFIX ?? "netsre",
    [string]$AlertEmail = $env:ALERT_EMAIL ?? "netops@example.com",
    [ValidateSet("private_endpoint_dns", "private_endpoint_http", "cross_hub_http", "onprem_http")]
    [string]$DependencyLatencyTarget = $env:DEPENDENCY_LATENCY_TARGET ?? "cross_hub_http",
    [ValidateRange(1, 30000)]
    [int]$DependencyLatencyMs = 3000,
    [ValidateRange(1, 30000)]
    [int]$DependencyLatencyAlertThresholdMs = 2000,
    [string]$SshKeyPath = $env:SSH_KEY_PATH ?? "$HOME/.ssh/id_rsa.pub",
    [string]$AdminUsername = $env:ADMIN_USERNAME ?? "azureuser",
    [ValidatePattern('^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:/(?:[0-9]|[12]\d|3[0-2]))?$')]
    [string]$AppGatewayAllowedSourceCidr,
    [SecureString]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($AppGatewayAllowedSourceCidr -match '/0$') {
    throw "AppGatewayAllowedSourceCidr cannot use a /0 prefix. Supply the presenter's public IPv4 address, normally as a /32."
}

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoDir = Split-Path -Parent $ScriptDir
$TemplateFile = Join-Path $RepoDir "infra" "modules" "observability-workload.bicep"
$AppGatewayScript = Join-Path $ScriptDir "configure-observability-appgw.ps1"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI (az) is not installed. See https://aka.ms/install-azure-cli"
    exit 1
}
try { az account show 2>&1 | Out-Null } catch {
    Write-Err "Not logged in. Run 'az login'."
    exit 1
}
if (-not (Test-Path $TemplateFile)) {
    Write-Err "Bicep template not found at $TemplateFile"
    exit 1
}
if (-not (Test-Path $SshKeyPath)) {
    Write-Err "No SSH public key found at $SshKeyPath"
    exit 1
}

$SshKeyData = (Get-Content $SshKeyPath -Raw).Trim()
if (-not $AdminPassword) {
    $AdminPassword = Read-Host "Enter admin password (for serial console access)" -AsSecureString
}
$PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))
if ([string]::IsNullOrEmpty($PlainPassword)) {
    Write-Err "A password is required."
    exit 1
}

Write-Info "Resolving the existing lab..."
$SpokeSubnetId = az network vnet subnet show -g $ResourceGroup `
    --vnet-name "$Prefix-spoke11-vnet" -n default --query id -o tsv
$LawId = az monitor log-analytics workspace show -g $ResourceGroup `
    -n "$Prefix-law" --query id -o tsv
$CrossHubIp = az vm show -g $ResourceGroup -n "$Prefix-spoke21-vm" `
    --show-details --query privateIps -o tsv
$StaticWebsiteFqdn = az deployment group show -g $ResourceGroup `
    -n private-link-deployment --query "properties.outputs.staticWebsiteFqdn.value" -o tsv 2>$null

if (-not $SpokeSubnetId -or -not $LawId -or -not $CrossHubIp -or -not $StaticWebsiteFqdn) {
    Write-Err "The base lab is incomplete. Deploy it with scripts\deploy.ps1 first."
    exit 1
}

$OnpremUrl = ""
$OnpremServerIp = az vm show -g $ResourceGroup -n "$Prefix-onprem-server" `
    --show-details --query privateIps -o tsv 2>$null
if ($OnpremServerIp) {
    $OnpremUrl = "http://$OnpremServerIp/"
    Write-Info "Including on-prem dependency: $OnpremUrl"
} else {
    Write-Warn "Optional on-prem server not found; deploy-onprem.ps1 -Stage device to add that dependency."
}

$DeploymentName = "$Prefix-observability-$(Get-Date -Format 'yyyyMMddHHmmss')"
$ParamsFile = Join-Path $env:TEMP "$DeploymentName.params.json"
$Params = [ordered]@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = [ordered]@{
        location = @{ value = $Location }
        observabilityLocation = @{ value = $ObservabilityLocation }
        prefix = @{ value = $Prefix }
        subnetId = @{ value = $SpokeSubnetId }
        logAnalyticsWorkspaceId = @{ value = $LawId }
        privateEndpointFqdn = @{ value = $StaticWebsiteFqdn }
        crossHubUrl = @{ value = "http://$CrossHubIp/" }
        onpremUrl = @{ value = $OnpremUrl }
        dependencyLatencyTarget = @{ value = $DependencyLatencyTarget }
        dependencyLatencyMs = @{ value = $DependencyLatencyMs }
        dependencyLatencyAlertThresholdMs = @{ value = $DependencyLatencyAlertThresholdMs }
        adminUsername = @{ value = $AdminUsername }
        adminPassword = @{ value = $PlainPassword }
        adminPublicKey = @{ value = $SshKeyData }
        alertEmail = @{ value = $AlertEmail }
    }
}
$Params | ConvertTo-Json -Depth 10 | Set-Content -Path $ParamsFile -Encoding utf8

try {
    Write-Info "Deploying telemetry API and Observability Agent..."
    $OutputsJson = az deployment group create -g $ResourceGroup `
        --name $DeploymentName `
        --template-file $TemplateFile `
        --parameters "@$ParamsFile" `
        --query properties.outputs -o json
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Observability extension deployment failed."
        exit 1
    }
} finally {
    Remove-Item $ParamsFile -ErrorAction SilentlyContinue
}

$Outputs = $OutputsJson | ConvertFrom-Json

# Azure Monitor issues require a subscription-to-AMW association. Set this lab's
# workspace as the default only when the subscription does not already have one;
# do not silently replace another team's existing issue workspace.
$SubscriptionId = az account show --query id -o tsv
$SettingsUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/microsoft.monitor/settings/default?api-version=2025-06-03-preview"
$ExistingDefaultAmw = az rest --method get --url $SettingsUrl --query "properties.defaultAzureMonitorWorkspace" -o tsv 2>$null
if (-not $ExistingDefaultAmw) {
    $SettingsBody = @{
        properties = @{
            defaultAzureMonitorWorkspace = $Outputs.azureMonitorWorkspaceId.value
        }
    } | ConvertTo-Json -Compress
    az rest --method put --url $SettingsUrl `
        --headers "Content-Type=application/json" `
        --body $SettingsBody -o none
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not associate the subscription with the Azure Monitor workspace."
        Write-Warn "Autonomous issue creation might require completing this association in the Azure portal."
    } else {
        Write-Info "Associated the subscription with $($Outputs.azureMonitorWorkspaceId.value) for Azure Monitor issues."
    }
} elseif ($ExistingDefaultAmw -ne $Outputs.azureMonitorWorkspaceId.value) {
    Write-Warn "The subscription already uses a different default Azure Monitor workspace:"
    Write-Warn "  $ExistingDefaultAmw"
    Write-Warn "It was preserved. Autonomous issues for this resource still target its configured workspace."
}

Write-Info "Waiting for cloud-init and verifying the API..."
$VerifyScript = @'
cloud-init status --wait >/dev/null
systemctl is-active --quiet netsre-observability-api
systemctl is-active --quiet netsre-synthetic-traffic
curl --fail --silent --show-error http://127.0.0.1:8080/healthz
'@
$VerifyScriptBytes = [Text.Encoding]::UTF8.GetBytes($VerifyScript)
$VerifyScriptBase64 = [Convert]::ToBase64String($VerifyScriptBytes)
$VerifyResult = az vm run-command invoke -g $ResourceGroup `
    -n $Outputs.apiVmName.value `
    --command-id RunShellScript `
    --scripts "echo $VerifyScriptBase64 | base64 -d | bash" `
    --query "value[0].message" -o tsv
if ($LASTEXITCODE -ne 0 -or ($VerifyResult -join "`n") -notmatch '"status":"ok"') {
    Write-Err "The VM deployed, but the telemetry API verification failed."
    Write-Err ($VerifyResult -join "`n")
    exit 1
}
Write-Info "Telemetry API and synthetic traffic service are healthy."

$AppGatewayEndpoint = ""
if ($AppGatewayAllowedSourceCidr) {
    if (-not (Test-Path $AppGatewayScript)) {
        throw "Application Gateway configuration script not found at $AppGatewayScript"
    }
    Write-Info "Configuring CIDR-restricted Hub1 Application Gateway ingress..."
    $AppGatewayEndpoint = @(& $AppGatewayScript `
        -ResourceGroup $ResourceGroup `
        -Prefix $Prefix `
        -AllowedSourceCidr $AppGatewayAllowedSourceCidr) | Select-Object -Last 1
    if (-not $AppGatewayEndpoint) {
        throw "Application Gateway ingress configuration did not return an endpoint."
    }
} else {
    Write-Warn "Public ingress was not configured. The demo will fall back to Azure VM Run Command."
    Write-Warn "Enable direct HTTP later with:"
    Write-Host "  .\scripts\configure-observability-appgw.ps1 -ResourceGroup `"$ResourceGroup`" -Prefix `"$Prefix`" -AllowedSourceCidr '<presenter-public-ip>/32'"
}

Write-Host ""
Write-Info "=== Observability extension deployed ==="
Write-Host "  API VM              : $($Outputs.apiVmName.value) ($($Outputs.apiPrivateIp.value):8080)"
Write-Host "  Application Insights: $($Outputs.applicationInsightsName.value)"
Write-Host "  Observability Agent : $($Outputs.observabilityAgentName.value)"
Write-Host "  Agent region        : $ObservabilityLocation"
if ($AppGatewayEndpoint) {
    Write-Host "  Public API endpoint : $AppGatewayEndpoint"
}
Write-Host ""
Write-Info "The API emits a synthetic transaction every 15 seconds."
Write-Info "The opt-in dependency-latency profile delays '$DependencyLatencyTarget' by ${DependencyLatencyMs}ms."
Write-Info "Inject pe-dns-override, UDR, NVA, peering, VPN, or on-prem faults to generate correlated application and infrastructure signals."
