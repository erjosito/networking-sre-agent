<#
.SYNOPSIS
    Tear down the Azure Networking SRE Agent test environment.

.DESCRIPTION
    Deletes the specified resource group and all resources within it.

.PARAMETER ResourceGroup
    Name of the resource group to delete (default: netsre-rg).

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\teardown.ps1
    .\teardown.ps1 -ResourceGroup "mylab-rg" -Yes
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP ?? "netsre-rg",
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

# Check if resource group exists
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

# Delete
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
