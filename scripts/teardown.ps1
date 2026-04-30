<#
.SYNOPSIS
    Tear down the Azure Networking SRE Agent test environment.

.DESCRIPTION
    Deletes the specified resource group and all resources within it.
    Also cleans up Connection Monitors from the NetworkWatcherRG and
    optionally removes the SRE Agent resource from its resource group.

.PARAMETER ResourceGroup
    Name of the resource group to delete (default: netsre-rg).

.PARAMETER Prefix
    Resource naming prefix (default: netsre). Used to find related
    Connection Monitors and SRE Agent resources.

.PARAMETER SreAgentResourceGroup
    Resource group containing the SRE Agent (default: empty, skips
    SRE Agent cleanup). Set to the agent's RG to delete it too.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\teardown.ps1
    .\teardown.ps1 -ResourceGroup "mylab-rg" -Prefix "mylab" -Yes
    .\teardown.ps1 -SreAgentResourceGroup "fabricnet" -Yes
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP ?? "netsre-rg",
    [string]$Prefix = $env:PREFIX ?? "netsre",
    [string]$SreAgentResourceGroup = "",
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info  { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Green }
function Write-Warn  { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err   { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Pre-flight
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI (az) is not installed."
    exit 1
}

###############################################################################
# 1. Delete Connection Monitors from NetworkWatcherRG
###############################################################################
Write-Info "Checking for Connection Monitors to clean up..."
$location = az group show --name $ResourceGroup --query location -o tsv 2>$null
if ($location) {
    $cmName = "$Prefix-connection-monitor"
    $cmExists = az network watcher connection-monitor show --name $cmName --location $location 2>$null
    if ($cmExists) {
        Write-Info "Deleting Connection Monitor '$cmName' from NetworkWatcher in $location..."
        az network watcher connection-monitor delete --name $cmName --location $location 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Connection Monitor '$cmName' deleted."
        } else {
            Write-Warn "Could not delete Connection Monitor '$cmName' (may require manual cleanup)."
        }
    } else {
        Write-Info "No Connection Monitor '$cmName' found."
    }

    # Also look for any other CMs that reference resources in this RG
    Write-Info "Scanning for other Connection Monitors referencing '$ResourceGroup'..."
    $allCms = az network watcher connection-monitor list --location $location --query "[].name" -o tsv 2>$null
    if ($allCms) {
        foreach ($cm in ($allCms -split "`n" | Where-Object { $_ -and $_ -ne $cmName })) {
            $cmDetail = az network watcher connection-monitor show --name $cm --location $location -o json 2>$null
            if ($cmDetail -and $cmDetail -match $ResourceGroup) {
                Write-Warn "Connection Monitor '$cm' references resources in '$ResourceGroup'."
                if ($Yes) {
                    Write-Info "Deleting Connection Monitor '$cm'..."
                    az network watcher connection-monitor delete --name $cm --location $location 2>$null
                } else {
                    Write-Warn "  Skipping (use -Yes to auto-delete). Delete manually: az network watcher connection-monitor delete --name $cm --location $location"
                }
            }
        }
    }
} else {
    Write-Warn "Resource group '$ResourceGroup' not found — skipping Connection Monitor cleanup."
}

###############################################################################
# 2. Optionally delete the SRE Agent
###############################################################################
if ($SreAgentResourceGroup) {
    $agentName = $Prefix
    Write-Info "Checking for SRE Agent '$agentName' in '$SreAgentResourceGroup'..."
    $agentExists = az resource show -g $SreAgentResourceGroup -n $agentName --resource-type "Microsoft.App/agents" 2>$null
    if ($agentExists) {
        Write-Warn "SRE Agent '$agentName' found in '$SreAgentResourceGroup'."
        if ($Yes) {
            Write-Info "Deleting SRE Agent '$agentName'..."
            az resource delete -g $SreAgentResourceGroup -n $agentName --resource-type "Microsoft.App/agents" 2>$null
            Write-Info "SRE Agent deleted."
        } else {
            Write-Warn "  Skipping (use -Yes to auto-delete)."
        }
    } else {
        Write-Info "No SRE Agent '$agentName' found in '$SreAgentResourceGroup'."
    }
}

###############################################################################
# 3. Delete the resource group
###############################################################################
$rgExists = az group show --name $ResourceGroup 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Resource group '$ResourceGroup' does not exist. Nothing to delete."
    exit 0
}

# List resources
Write-Info "Resources in '$ResourceGroup':"
az resource list --resource-group $ResourceGroup --query "[].{Name:name, Type:type}" --output table
Write-Host ""

# Confirm deletion
if (-not $Yes) {
    Write-Warn "⚠️  This will permanently delete ALL resources in '$ResourceGroup'."
    $Confirm = Read-Host "Are you sure? Type the resource group name to confirm"
    if ($Confirm -ne $ResourceGroup) {
        Write-Info "Aborted."
        exit 0
    }
}

Write-Info "Deleting resource group '$ResourceGroup'..."
Write-Warn "This may take several minutes (VPN Gateways are slow to delete)."
az group delete --name $ResourceGroup --yes --no-wait

if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to initiate deletion."
    exit 1
}

Write-Info "Deletion initiated (running in background with --no-wait)."
Write-Info "Monitor progress: az group show --name $ResourceGroup --query properties.provisioningState -o tsv"
Write-Info "Done! 🗑️"
