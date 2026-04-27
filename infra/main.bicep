@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name used to derive resource names')
@minLength(1)
@maxLength(20)
param environmentName string

@description('VM size')
param vmSize string = 'Standard_B1s'

@description('Admin username for VM access')
param adminUsername string = 'azureuser'

@description('SSH public key for VM access')
@secure()
param sshPublicKey string

@description('Actual Budget container image')
param actualServerImage string = 'actualbudget/actual-server:latest'

@description('Domain name for HTTPS via Caddy (e.g. budget.example.com). Leave empty for HTTP-only on port 5006.')
param domainName string = ''

// Derived names
var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName))
var vmName = '${environmentName}-vm'
var vnetName = '${environmentName}-vnet'
var subnetName = '${environmentName}-subnet'
var nsgName = '${environmentName}-nsg'
var publicIpName = '${environmentName}-pip'
var nicName = '${environmentName}-nic'
var useCaddy = !empty(domainName)

// -- cloud-init: Docker + Caddy + hardening --
var cloudInitWithCaddy = '''
#cloud-config
package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - unattended-upgrades
  - fail2ban

write_files:
  - path: /opt/actual-budget/docker-compose.yml
    content: |
      services:
        caddy:
          image: caddy:2
          restart: unless-stopped
          ports:
            - "80:80"
            - "443:443"
          volumes:
            - /opt/actual-budget/Caddyfile:/etc/caddy/Caddyfile
            - caddy_data:/data
          depends_on:
            - actual-server
        actual-server:
          image: {IMAGE}
          restart: unless-stopped
          volumes:
            - /opt/actual-budget/data:/data
          healthcheck:
            test: ["CMD-SHELL", "curl -f http://localhost:5006/ || exit 1"]
            interval: 30s
            timeout: 10s
            retries: 3
      volumes:
        caddy_data:
  - path: /opt/actual-budget/Caddyfile
    content: |
      {DOMAIN} {
          reverse_proxy actual-server:5006
      }
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

runcmd:
  # Install Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
  # Enable fail2ban
  - systemctl enable fail2ban
  - systemctl start fail2ban
  # Create data directory
  - mkdir -p /opt/actual-budget/data
  # Start Caddy + Actual via Docker Compose
  - cd /opt/actual-budget && docker compose up -d
'''

var cloudInitHttpOnly = '''
#cloud-config
package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - unattended-upgrades
  - fail2ban

write_files:
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

runcmd:
  # Install Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
  # Enable fail2ban
  - systemctl enable fail2ban
  - systemctl start fail2ban
  # Create data directory
  - mkdir -p /opt/actual-budget/data
  # Run Actual Budget container (HTTP only, port 5006)
  - docker run -d --name actual-server --restart unless-stopped -p 5006:5006 -v /opt/actual-budget/data:/data --health-cmd "curl -f http://localhost:5006/ || exit 1" --health-interval 30s --health-timeout 10s --health-retries 3 {IMAGE}
'''

var cloudInitFormatted = useCaddy
  ? replace(replace(cloudInitWithCaddy, '{IMAGE}', actualServerImage), '{DOMAIN}', domainName)
  : replace(cloudInitHttpOnly, '{IMAGE}', actualServerImage)

// NSG rules: HTTPS + HTTP (for cert validation) when Caddy is used; port 5006 when not
var nsgRulesWithCaddy = [
  {
    name: 'AllowHTTP'
    properties: {
      priority: 1000
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '80'
    }
  }
  {
    name: 'AllowHTTPS'
    properties: {
      priority: 1001
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
]

var nsgRulesHttpOnly = [
  {
    name: 'AllowActualBudget'
    properties: {
      priority: 1000
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '5006'
    }
  }
]

// -- Network Security Group (no SSH!) --
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: useCaddy ? nsgRulesWithCaddy : nsgRulesHttpOnly
  }
}

// -- Virtual Network --
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// -- Public IP --
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${environmentName}-${resourceToken}'
    }
  }
}

// -- Network Interface --
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// -- Virtual Machine --
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInitFormatted)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 30
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// -- Outputs --
@description('Public IP address of the VM')
output publicIpAddress string = publicIp.properties.ipAddress

@description('URL to access Actual Budget')
output actualUrl string = useCaddy ? 'https://${domainName}' : 'http://${publicIp.properties.dnsSettings.fqdn}:5006'

@description('FQDN of the VM (Azure DNS label)')
output fqdn string = publicIp.properties.dnsSettings.fqdn

@description('VM name')
output vmName string = vm.name

@description('Whether Caddy HTTPS is enabled')
output httpsEnabled bool = useCaddy
