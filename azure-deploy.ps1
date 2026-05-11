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
#!/bin/bash
if [ -f /opt/actual-budget/docker-compose.yml ]; then
    cd /opt/actual-budget
    echo "=== Pulling latest images ==="
    docker compose pull
    echo ""
    echo "=== Restarting containers ==="
    docker compose up -d
    echo ""
    echo "=== Updated via Docker Compose (Caddy + Actual) ==="
else
    echo "=== Pulling latest image ==="
    docker pull actualbudget/actual-server:latest
    docker stop actual-server 2>/dev/null || true
    docker rm actual-server 2>/dev/null || true
    echo ""
    echo "=== Starting container ==="
    docker run -d --name actual-server --restart unless-stopped -p 5006:5006 -v /opt/actual-budget/data:/data actualbudget/actual-server:latest
    echo ""
    echo "=== Updated standalone Actual server ==="
fi

echo ""
echo "=== Verifying containers ==="
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo ""
echo "=== Health check (waiting up to 30s) ==="
for i in 1 2 3 4 5 6; do
    if curl -sf http://localhost:5006/ > /dev/null 2>&1; then
        echo "  OK - Actual Budget is responding on port 5006"
        exit 0
    fi
    echo "  Attempt $i/6 - waiting 5s..."
    sleep 5
done
echo "  WARN - Actual Budget did not respond within 30s. Check logs with:"
echo "    docker logs actual-server --tail 20"
exit 1
'@

    # Write script to temp file to avoid PowerShell multi-line string mangling
    $tempScript = [System.IO.Path]::GetTempFileName() + ".sh"
    Set-Content -Path $tempScript -Value $updateScript -NoNewline

    $result = az vm run-command invoke `
        --resource-group $ResourceGroupName `
        --name $VmName `
        --command-id RunShellScript `
        --scripts "@$tempScript" `
        --output json | ConvertFrom-Json

    Remove-Item $tempScript -ErrorAction SilentlyContinue

    # value[0] = stdout, value[1] = stderr
    $stdout = if ($result.value.Count -ge 1) { $result.value[0].message } else { "" }
    $stderr = if ($result.value.Count -ge 2) { $result.value[1].message } else { "" }
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Warn "stderr: $stderr" }

    Write-Host ""
    if ($stdout -match "OK - Actual Budget is responding") {
        Write-Info "Update complete and verified!"
    } elseif ($stdout -match "WARN") {
        Write-Warn "Update may have failed. Check the output above."
        exit 1
    } else {
        Write-Warn "Update finished but health check result is unclear. Verify manually."
    }
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
