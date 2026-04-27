# Azure VM Deployment for Actual Budget

Deploy [Actual Budget](https://github.com/actualbudget/actual) on an Azure **B1s VM** (~$7.50/month) running Docker. Optionally add **Caddy** for automatic HTTPS with Let's Encrypt.

> **Actual Budget** is a 100% free and open-source local-first personal finance tool. Learn more at [actualbudget.org](https://actualbudget.org).

## Architecture

### With domain (HTTPS via Caddy)

```
Internet                     Azure VM (B1s)
   |                      +-----------------------------+
   | HTTPS :443           | Docker Compose              |
   +--------------------->| +--------+  +-------------+ |
                          | | Caddy  |->| actual-server| |
   (auto Let's Encrypt)  | | :80/443|  | :5006 (int) | |
                          | +--------+  +-------------+ |
                          +-----------------------------+
```

### Without domain (HTTP only)

```
Internet                     Azure VM (B1s)
   |                      +-----------------------------+
   | HTTP :5006           | Docker                      |
   +--------------------->| +-------------+             |
                          | | actual-server|             |
                          | | :5006        |             |
                          | +-------------+             |
                          +-----------------------------+
```

## Security Features

| Feature | Description |
|---------|-------------|
| **No SSH port** | Port 22 is closed in the NSG. Management via Azure Run Command. |
| **HTTPS** (with domain) | Caddy auto-provisions and renews Let's Encrypt certificates |
| **Automatic OS updates** | `unattended-upgrades` patches security vulnerabilities daily |
| **fail2ban** | Blocks brute-force login attempts |
| **SSH key-only auth** | Password authentication is disabled on the VM |
| **Docker isolation** | App runs in a container, not directly on the host |
| **Actual Budget auth** | Server password required on first login |

## Prerequisites

- **Azure CLI**: [Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- **Azure Subscription**: With permissions to create VMs
- **SSH Key Pair**: For VM provisioning (`ssh-keygen -t ed25519`)
- **Domain name** (optional): For HTTPS — create an A record after deployment

## Quick Start

Clone this repository:

```bash
git clone https://github.com/philjn/actual-budget-azure.git
cd actual-budget-azure
```

### Deploy with HTTPS (recommended)

```powershell
.\azure-deploy.ps1 -ResourceGroupName "actual-budget-rg" -DomainName "budget.yourdomain.com"
```

After deployment, create a DNS A record: `budget.yourdomain.com` -> `<Public IP from output>`

### Deploy without domain (HTTP only)

```powershell
.\azure-deploy.ps1 -ResourceGroupName "actual-budget-rg"
```

### Bash equivalents

```bash
# HTTPS
./azure-deploy.sh -g actual-budget-rg -d budget.yourdomain.com

# HTTP only
./azure-deploy.sh -g actual-budget-rg
```

Wait 2-3 minutes after deployment for cloud-init to finish, then open the URL from the output.

## Script Parameters

### PowerShell (`azure-deploy.ps1`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ResourceGroupName` | Yes | - | Azure resource group name |
| `Location` | No | `eastus` | Azure region |
| `EnvironmentName` | No | `actual-budget` | Name prefix for resources |
| `VmSize` | No | `Standard_B1s` | VM size |
| `AdminUsername` | No | `azureuser` | VM admin username |
| `SshKeyPath` | No | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `DomainName` | No | (empty) | Domain for HTTPS (e.g. `budget.example.com`) |
| `-Update` | No | - | Update to latest Actual Budget image |

### Bash (`azure-deploy.sh`)

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `-g, --resource-group` | Yes | - | Azure resource group name |
| `-l, --location` | No | `eastus` | Azure region |
| `-n, --name` | No | `actual-budget` | Name prefix for resources |
| `-s, --vm-size` | No | `Standard_B1s` | VM size |
| `-u, --admin-username` | No | `azureuser` | VM admin username |
| `-k, --ssh-key-path` | No | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `-d, --domain` | No | (empty) | Domain for HTTPS |
| `--update` | No | - | Update to latest Actual Budget image |

## What Gets Deployed

| Resource | Purpose | Est. Monthly Cost |
|----------|---------|-------------------|
| **Virtual Machine** (B1s) | 1 vCPU, 1 GiB RAM | ~$7.50 |
| **Managed Disk** (30 GiB Premium SSD) | OS + data | (included) |
| **Public IP** (Static) | External access | ~$3 |
| **VNet + Subnet + NSG** | Networking + firewall | Free |
| **Total** | | **~$10.50/month** |

## Updating the Server

Updates use **Azure Run Command** — no SSH access needed:

```powershell
.\azure-deploy.ps1 -Update -ResourceGroupName "actual-budget-rg"
```

```bash
./azure-deploy.sh --update -g actual-budget-rg
```

This pulls the latest `actualbudget/actual-server` image and restarts the container. Data is preserved.

### What happens during an update

- If Caddy is configured: `docker compose pull && docker compose up -d` (updates both Caddy and Actual)
- If HTTP-only: pulls and recreates the standalone Actual container

## Backup and Recovery

### Create backup (via Azure Run Command)

```bash
az vm run-command invoke \
    --resource-group actual-budget-rg \
    --name actual-budget-vm \
    --command-id RunShellScript \
    --scripts "tar -czf /tmp/actual-backup.tar.gz /opt/actual-budget/data/ && echo 'Backup created at /tmp/actual-backup.tar.gz'"
```

### Download backup

To download the backup, you'll need to temporarily open SSH or use Azure Bastion. Alternatively, set up a cron job to copy backups to Azure Blob Storage.

## Configuration

Update environment variables via Azure Run Command:

```bash
az vm run-command invoke \
    --resource-group actual-budget-rg \
    --name actual-budget-vm \
    --command-id RunShellScript \
    --scripts "docker stop actual-server && docker rm actual-server && docker run -d --name actual-server --restart unless-stopped -p 5006:5006 -v /opt/actual-budget/data:/data -e ACTUAL_LOGIN_METHOD=password -e ACTUAL_UPLOAD_FILE_SIZE_LIMIT_MB=50 actualbudget/actual-server:latest"
```

See [Actual Budget server configuration](https://actualbudget.org/docs/config/) for all options.

## Troubleshooting

### Check cloud-init status

```bash
az vm run-command invoke \
    --resource-group actual-budget-rg \
    --name actual-budget-vm \
    --command-id RunShellScript \
    --scripts "cloud-init status && docker ps"
```

### View container logs

```bash
az vm run-command invoke \
    --resource-group actual-budget-rg \
    --name actual-budget-vm \
    --command-id RunShellScript \
    --scripts "docker logs --tail 50 actual-server"
```

### HTTPS not working

1. Verify DNS A record is pointing to the VM's public IP
2. Check Caddy logs:

```bash
az vm run-command invoke \
    --resource-group actual-budget-rg \
    --name actual-budget-vm \
    --command-id RunShellScript \
    --scripts "cd /opt/actual-budget && docker compose logs caddy --tail 50"
```

## Repository Structure

```
actual-budget-azure/
├── README.md               # This file
├── LICENSE                  # MIT License
├── .gitignore              # Azure/IDE artifacts
├── azure-deploy.ps1        # PowerShell deployment script
├── azure-deploy.sh         # Bash deployment script
└── infra/
    ├── main.bicep          # Azure Bicep IaC template
    └── main.bicepparam     # Bicep parameters
```

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

Actual Budget itself is also [MIT licensed](https://github.com/actualbudget/actual/blob/master/LICENSE.txt).
