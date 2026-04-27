# Azure VM Deployment Script for Actual Budget
# Deploys Actual Budget on an Azure VM with optional Caddy HTTPS.
# Uses Azure Run Command for updates (no SSH needed).
#
# Usage:
#   .\azure-deploy.ps1 -ResourceGroupName "actual-budget-rg"
#   .\azure-deploy.ps1 -ResourceGroupName "actual-budget-rg" -DomainName "budget.example.com"
#   .\azure-deploy.ps1 -Update -ResourceGroupName "actual-budget-rg"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName = "actual-budget",

    [Parameter(Mandatory = $false)]
    [string]$VmSize = "Standard_B1s",

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = "azureuser",

    [Parameter(Mandatory = $false)]
    [string]$SshKeyPath = "$HOME/.ssh/id_ed25519.pub",

    [Parameter(Mandatory = $false)]
    [string]$DomainName = "",

    [Parameter(Mandatory = $false)]
    [switch]$Update
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }

# Check Azure CLI
if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
}

# Verify Azure login
$loginCheck = az account show 2>$null
if (-not $loginCheck) {
    Write-Warn "Not logged into Azure. Running 'az login'..."
    az login
}

$VmName = "$EnvironmentName-vm"

# -- Update mode: use Azure Run Command (no SSH) --
if ($Update) {
    Write-Info "Updating Actual Budget on VM '$VmName'..."

    $updateScript = @'
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
'@

    $result = az vm run-command invoke `
        --resource-group $ResourceGroupName `
        --name $VmName `
        --command-id RunShellScript `
        --scripts $updateScript `
        --output json | ConvertFrom-Json

    $output = $result.value | Where-Object { $_.code -like '*stdout*' } | Select-Object -ExpandProperty message
    Write-Host $output

    Write-Host ""
    Write-Info "Update complete!"
    exit 0
}

# -- Full deployment via Bicep --
$BicepFile = Join-Path $PSScriptRoot "infra" "main.bicep"
if (!(Test-Path $BicepFile)) {
    Write-Error "Bicep template not found at $BicepFile"
    exit 1
}

# Read SSH public key
$resolvedKeyPath = [System.IO.Path]::GetFullPath($SshKeyPath.Replace("~", $HOME))
if (!(Test-Path $resolvedKeyPath)) {
    Write-Error "SSH public key not found at $resolvedKeyPath. Generate one with: ssh-keygen -t ed25519"
    exit 1
}
$sshKey = (Get-Content $resolvedKeyPath -Raw).Trim()

Write-Info "Deploying Actual Budget VM"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  Location:       $Location"
Write-Info "  VM Size:        $VmSize"
if ($DomainName) {
    Write-Info "  Domain:         $DomainName (HTTPS via Caddy)"
} else {
    Write-Info "  Domain:         (none - HTTP only on port 5006)"
}
Write-Host ""

# Create resource group
Write-Info "Creating resource group '$ResourceGroupName' in '$Location'..."
az group create --name $ResourceGroupName --location $Location --output none

# Build parameters
$bicepParams = @(
    "environmentName=$EnvironmentName"
    "vmSize=$VmSize"
    "adminUsername=$AdminUsername"
    "sshPublicKey=$sshKey"
)
if ($DomainName) {
    $bicepParams += "domainName=$DomainName"
}

# Deploy Bicep template
Write-Info "Deploying infrastructure (this may take a few minutes)..."
$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $BicepFile `
    --parameters $bicepParams `
    --query "properties.outputs" `
    --output json | ConvertFrom-Json

$publicIp = $deploymentOutput.publicIpAddress.value
$actualUrl = $deploymentOutput.actualUrl.value
$fqdn = $deploymentOutput.fqdn.value
$httpsEnabled = $deploymentOutput.httpsEnabled.value

Write-Host ""
Write-Host "================================================================"
Write-Info "Deployment complete!"
Write-Host ""
Write-Host "  Actual Budget:  $actualUrl"
Write-Host "  Public IP:      $publicIp"
Write-Host "  Azure FQDN:     $fqdn"
if ($httpsEnabled) {
    Write-Host ""
    Write-Host "  IMPORTANT: Create a DNS A record:"
    Write-Host "    $DomainName  ->  $publicIp"
}
Write-Host ""
Write-Host "  cloud-init is installing Docker and starting the container."
Write-Host "  This takes 2-3 minutes after VM creation."
Write-Host ""
Write-Host "  To update later:  .\azure-deploy.ps1 -Update -ResourceGroupName $ResourceGroupName"
Write-Host "  To delete:        az group delete --name $ResourceGroupName --yes"
Write-Host "================================================================"
if ($httpsEnabled) {
    Write-Host ""
    Write-Warn "HTTPS will only work after the DNS A record is active."
    Write-Warn "Until then, Caddy will retry certificate issuance automatically."
}
