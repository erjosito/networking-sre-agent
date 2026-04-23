#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy the Azure Networking SRE Agent test environment
# Usage: ./deploy.sh [--resource-group <rg>] [--location <location>]
#                    [--prefix <prefix>] [--ssh-key <path>]
#                    [--admin-username <user>] [--admin-password <pass>]
###############################################################################

# Default parameter values
RESOURCE_GROUP="${RESOURCE_GROUP:-netsre-rg}"
LOCATION="${LOCATION:-eastus2}"
PREFIX="${PREFIX:-netsre}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
ADMIN_PASSWORD=""

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --location)       LOCATION="$2";       shift 2 ;;
        --prefix)         PREFIX="$2";          shift 2 ;;
        --ssh-key)        SSH_KEY_PATH="$2";    shift 2 ;;
        --admin-username) ADMIN_USERNAME="$2";  shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2";  shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --resource-group <name>   Resource group name (default: netsre-rg)"
            echo "  --location <region>       Azure region (default: eastus2)"
            echo "  --prefix <prefix>         Resource name prefix (default: netsre)"
            echo "  --ssh-key <path>          Path to SSH public key (default: ~/.ssh/id_rsa.pub)"
            echo "  --admin-username <user>   VM admin username (default: azureuser)"
            echo "  --admin-password <pass>   VM admin password (if no SSH key)"
            echo "  -h, --help                Show this help message"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve the script directory to find the infra/ folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE_FILE="$REPO_DIR/infra/main.bicep"

###############################################################################
# Pre-flight checks
###############################################################################
info "Running pre-flight checks..."

if ! command -v az &>/dev/null; then
    error "Azure CLI (az) is not installed. See https://aka.ms/install-azure-cli"
    exit 1
fi

if ! az account show &>/dev/null; then
    error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    error "Bicep template not found at $TEMPLATE_FILE"
    exit 1
fi

# Determine authentication method
AUTH_PARAMS=""
if [[ -f "${SSH_KEY_PATH/#\~/$HOME}" ]]; then
    RESOLVED_KEY="${SSH_KEY_PATH/#\~/$HOME}"
    SSH_KEY_DATA="$(cat "$RESOLVED_KEY")"
    AUTH_PARAMS="adminPublicKey=$SSH_KEY_DATA"
    info "Using SSH key: $RESOLVED_KEY"
else
    error "No SSH key found at $SSH_KEY_PATH."
    error "Generate a key with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

# Always require a password for serial console access
if [[ -z "$ADMIN_PASSWORD" ]]; then
    read -s -p "Enter admin password (for serial console access): " ADMIN_PASSWORD
    echo ""
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        error "A password is required for serial console access."
        exit 1
    fi
fi
AUTH_PARAMS="$AUTH_PARAMS adminPassword=$ADMIN_PASSWORD"

SUBSCRIPTION=$(az account show --query name -o tsv)
info "Subscription : $SUBSCRIPTION"
info "Resource Group: $RESOURCE_GROUP"
info "Location      : $LOCATION"
info "Prefix        : $PREFIX"
echo ""
warn "⏱  This deployment takes approximately 30-45 minutes."
warn "   VPN Gateways are the slowest component (~25-30 min each)."
echo ""

###############################################################################
# Deploy
###############################################################################
info "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

info "Starting Bicep deployment (this will take a while)..."
DEPLOY_START=$(date +%s)

az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE_FILE" \
    --parameters \
        prefix="$PREFIX" \
        adminUsername="$ADMIN_USERNAME" \
        $AUTH_PARAMS \
    --name "netsre-$(date +%Y%m%d-%H%M%S)" \
    --output none \
    --no-wait false

DEPLOY_END=$(date +%s)
DEPLOY_DURATION=$(( (DEPLOY_END - DEPLOY_START) / 60 ))

info "Deployment completed in ~${DEPLOY_DURATION} minutes."

###############################################################################
# Print outputs
###############################################################################
echo ""
info "=== Deployment Outputs ==="
az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$(az deployment group list --resource-group "$RESOURCE_GROUP" --query '[0].name' -o tsv)" \
    --query properties.outputs \
    --output table 2>/dev/null || warn "Could not retrieve deployment outputs."

echo ""
info "=== Quick Reference ==="
echo "  Resource Group : $RESOURCE_GROUP"
echo "  Location       : $LOCATION"
echo "  Admin User     : $ADMIN_USERNAME"
echo ""
info "Next steps:"
echo "  1. Verify health:       ./scripts/check-health.sh --resource-group $RESOURCE_GROUP"
echo "  2. Inject a fault:      ./scripts/inject-fault.sh --fault vpn-disconnect --resource-group $RESOURCE_GROUP"
echo "  3. Tear down when done: ./scripts/teardown.sh --resource-group $RESOURCE_GROUP"
echo ""
info "Done! 🚀"
