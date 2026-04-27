#!/bin/bash
# Azure VM Deployment Script for Actual Budget
# Deploys Actual Budget on an Azure VM with optional Caddy HTTPS.
# Uses Azure Run Command for updates (no SSH needed).
#
# Usage:
#   ./azure-deploy.sh -g <resource-group>
#   ./azure-deploy.sh -g <resource-group> -d budget.example.com
#   ./azure-deploy.sh --update -g <resource-group>

set -e

# Default values
RESOURCE_GROUP=""
LOCATION="eastus"
ENVIRONMENT_NAME="actual-budget"
VM_SIZE="Standard_B1s"
ADMIN_USERNAME="azureuser"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
DOMAIN_NAME=""
UPDATE_ONLY=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 -g <resource-group> [options]"
    echo ""
    echo "Deploy Actual Budget on an Azure VM."
    echo ""
    echo "Required:"
    echo "  -g, --resource-group    Azure resource group name"
    echo ""
    echo "Optional:"
    echo "  -l, --location          Azure region (default: eastus)"
    echo "  -n, --name              Environment name prefix (default: actual-budget)"
    echo "  -s, --vm-size           VM size (default: Standard_B1s)"
    echo "  -u, --admin-username    Admin username (default: azureuser)"
    echo "  -k, --ssh-key-path      SSH public key path (default: ~/.ssh/id_rsa.pub)"
    echo "  -d, --domain            Domain for HTTPS via Caddy (e.g. budget.example.com)"
    echo "  --update                Update existing VM to latest Actual Budget image"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -g actual-budget-rg                                    # HTTP only"
    echo "  $0 -g actual-budget-rg -d budget.example.com              # HTTPS via Caddy"
    echo "  $0 --update -g actual-budget-rg                           # Update to latest"
    exit 1
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        -l|--location) LOCATION="$2"; shift 2 ;;
        -n|--name) ENVIRONMENT_NAME="$2"; shift 2 ;;
        -s|--vm-size) VM_SIZE="$2"; shift 2 ;;
        -u|--admin-username) ADMIN_USERNAME="$2"; shift 2 ;;
        -k|--ssh-key-path) SSH_KEY_PATH="$2"; shift 2 ;;
        -d|--domain) DOMAIN_NAME="$2"; shift 2 ;;
        --update) UPDATE_ONLY=true; shift ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
    log_error "Resource group name is required"
    usage
fi

# Check Azure CLI
if ! command -v az &> /dev/null; then
    log_error "Azure CLI is not installed. Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Verify Azure login
if ! az account show &> /dev/null; then
    log_warn "Not logged into Azure. Running 'az login'..."
    az login
fi

VM_NAME="${ENVIRONMENT_NAME}-vm"

# -- Update mode: Azure Run Command (no SSH) --
if [[ "$UPDATE_ONLY" == true ]]; then
    log_info "Updating Actual Budget on VM '$VM_NAME'..."

    UPDATE_SCRIPT='
if [ -f /opt/actual-budget/docker-compose.yml ]; then
    cd /opt/actual-budget
    docker compose pull
    docker compose up -d
    echo "Updated via Docker Compose (Caddy + Actual)"
else
    docker pull actualbudget/actual-server:latest
    docker stop actual-server && docker rm actual-server
    docker run -d --name actual-server --restart unless-stopped -p 5006:5006 -v /opt/actual-budget/data:/data --health-cmd "curl -f http://localhost:5006/ || exit 1" --health-interval 30s --health-timeout 10s --health-retries 3 actualbudget/actual-server:latest
    echo "Updated standalone Actual server"
fi
'

    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "$UPDATE_SCRIPT" \
        --output table

    echo ""
    log_info "Update complete!"
    exit 0
fi

# -- Full deployment via Bicep --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_FILE="$SCRIPT_DIR/infra/main.bicep"

if [[ ! -f "$BICEP_FILE" ]]; then
    log_error "Bicep template not found at $BICEP_FILE"
    exit 1
fi

# Read SSH public key
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log_error "SSH public key not found at $SSH_KEY_PATH"
    log_error "Generate one with: ssh-keygen -t ed25519"
    exit 1
fi
SSH_KEY=$(cat "$SSH_KEY_PATH")

log_info "Deploying Actual Budget VM"
log_info "  Resource Group: $RESOURCE_GROUP"
log_info "  Location:       $LOCATION"
log_info "  VM Size:        $VM_SIZE"
if [[ -n "$DOMAIN_NAME" ]]; then
    log_info "  Domain:         $DOMAIN_NAME (HTTPS via Caddy)"
else
    log_info "  Domain:         (none - HTTP only on port 5006)"
fi
echo ""

# Create resource group
log_info "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

# Build parameters
PARAMS="environmentName=$ENVIRONMENT_NAME vmSize=$VM_SIZE adminUsername=$ADMIN_USERNAME sshPublicKey=$SSH_KEY"
if [[ -n "$DOMAIN_NAME" ]]; then
    PARAMS="$PARAMS domainName=$DOMAIN_NAME"
fi

# Deploy Bicep template
log_info "Deploying infrastructure (this may take a few minutes)..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$BICEP_FILE" \
    --parameters $PARAMS \
    --query "properties.outputs" \
    --output json)

PUBLIC_IP=$(echo "$DEPLOYMENT_OUTPUT" | grep -o '"publicIpAddress"[^}]*' | grep -o '"value":"[^"]*"' | cut -d'"' -f4)
ACTUAL_URL=$(echo "$DEPLOYMENT_OUTPUT" | grep -o '"actualUrl"[^}]*' | grep -o '"value":"[^"]*"' | cut -d'"' -f4)
FQDN=$(echo "$DEPLOYMENT_OUTPUT" | grep -o '"fqdn"[^}]*' | grep -o '"value":"[^"]*"' | cut -d'"' -f4)

echo ""
echo "================================================================"
log_info "Deployment complete!"
echo ""
echo "  Actual Budget:  $ACTUAL_URL"
echo "  Public IP:      $PUBLIC_IP"
echo "  Azure FQDN:     $FQDN"
if [[ -n "$DOMAIN_NAME" ]]; then
    echo ""
    echo "  IMPORTANT: Create a DNS A record:"
    echo "    $DOMAIN_NAME  ->  $PUBLIC_IP"
fi
echo ""
echo "  cloud-init is installing Docker and starting the container."
echo "  This takes 2-3 minutes after VM creation."
echo ""
echo "  To update later:  $0 --update -g $RESOURCE_GROUP"
echo "  To delete:        az group delete --name $RESOURCE_GROUP --yes"
echo "================================================================"
if [[ -n "$DOMAIN_NAME" ]]; then
    echo ""
    log_warn "HTTPS will only work after the DNS A record is active."
    log_warn "Until then, Caddy will retry certificate issuance automatically."
fi
