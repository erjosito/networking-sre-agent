#!/bin/bash
set -euo pipefail

###############################################################################
# Tear down the Azure Networking SRE Agent test environment
# Usage: ./teardown.sh [--resource-group <rg>] [--yes]
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-netsre-rg}"
SKIP_CONFIRM=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --yes|-y)         SKIP_CONFIRM=true;   shift   ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --resource-group <name>   Resource group to delete (default: netsre-rg)"
            echo "  --yes, -y                 Skip confirmation prompt"
            echo "  -h, --help                Show this help message"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# Pre-flight
if ! command -v az &>/dev/null; then
    error "Azure CLI (az) is not installed."
    exit 1
fi

# Check if resource group exists
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    warn "Resource group '$RESOURCE_GROUP' does not exist. Nothing to delete."
    exit 0
fi

# List resources
info "Resources in '$RESOURCE_GROUP':"
az resource list --resource-group "$RESOURCE_GROUP" --query "[].{Name:name, Type:type}" --output table
echo ""

# Confirm deletion
if [[ "$SKIP_CONFIRM" != true ]]; then
    warn "⚠️  This will permanently delete ALL resources in '$RESOURCE_GROUP'."
    read -rp "Are you sure? Type the resource group name to confirm: " CONFIRM
    if [[ "$CONFIRM" != "$RESOURCE_GROUP" ]]; then
        info "Aborted."
        exit 0
    fi
fi

# Delete
info "Deleting resource group '$RESOURCE_GROUP'..."
warn "This may take several minutes (VPN Gateways are slow to delete)."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

info "Deletion initiated (running in background with --no-wait)."
info "Monitor progress: az group show --name $RESOURCE_GROUP --query properties.provisioningState -o tsv"
info "Done! 🗑️"
