###################################################
# Local Bootstrap Scripts
###################################################

locals {
  #################################################
  # Trivy Installation Script
  # Runs only on the GitHub Actions VM
  #################################################

  install_trivy_script = <<-SCRIPT
    #!/usr/bin/env bash

    set -Eeuo pipefail

    LOG_FILE="/var/log/install-trivy.log"

    exec > >(tee -a "$${LOG_FILE}") 2>&1

    echo "[$(date -Is)] Starting Trivy installation"

    export DEBIAN_FRONTEND=noninteractive

    wait_for_apt() {
      echo "[$(date -Is)] Waiting for existing apt/dpkg operations"

      while \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1
      do
        sleep 10
      done
    }

    if command -v trivy >/dev/null 2>&1; then
      echo "[$(date -Is)] Trivy already installed"
      trivy --version
      exit 0
    fi

    wait_for_apt

    apt-get update -y
    apt-get install -y wget apt-transport-https gnupg ca-certificates

    mkdir -p /usr/share/keyrings

    wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
      | gpg --dearmor \
      | tee /usr/share/keyrings/trivy.gpg >/dev/null

    chmod 644 /usr/share/keyrings/trivy.gpg

    echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
      > /etc/apt/sources.list.d/trivy.list

    wait_for_apt

    apt-get update -y
    apt-get install -y trivy

    echo "[$(date -Is)] Trivy installation completed"

    trivy --version
  SCRIPT

  #################################################
  # Tools VM Installation Script
  # Installs Docker and starts:
  # 1. SonarQube
  # 2. Nexus Repository
  #################################################

  install_tools_script = <<-SCRIPT
    #!/usr/bin/env bash

    set -Eeuo pipefail

    LOG_FILE="/var/log/install-tools.log"

    exec > >(tee -a "$${LOG_FILE}") 2>&1

    echo "[$(date -Is)] Starting Tools VM bootstrap"

    export DEBIAN_FRONTEND=noninteractive

    wait_for_apt() {
      echo "[$(date -Is)] Waiting for existing apt/dpkg operations"

      while \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1
      do
        sleep 10
      done
    }

    wait_for_apt

    apt-get update -y

    apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      gnupg \
      jq \
      lsb-release

    if ! command -v docker >/dev/null 2>&1; then
      echo "[$(date -Is)] Installing Docker"

      curl -fsSL https://get.docker.com | sh
    else
      echo "[$(date -Is)] Docker already installed"
    fi

    systemctl enable docker
    systemctl start docker

    echo "[$(date -Is)] Docker version"
    docker --version

    #################################################
    # Create persistent Docker volumes
    #################################################

    docker volume create sonarqube_data
    docker volume create sonarqube_extensions
    docker volume create sonarqube_logs
    docker volume create nexus_data

    #################################################
    # SonarQube host configuration
    #################################################

    sysctl -w vm.max_map_count=524288
    sysctl -w fs.file-max=131072

    cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
    vm.max_map_count=524288
    fs.file-max=131072
    EOF

    #################################################
    # Docker network
    #################################################

    if ! docker network inspect devops-tools >/dev/null 2>&1; then
      docker network create devops-tools
    fi

    #################################################
    # SonarQube container
    #################################################

    if docker ps -a --format '{{.Names}}' | grep -qx sonarqube; then
      echo "[$(date -Is)] Removing existing SonarQube container"
      docker rm -f sonarqube
    fi

    echo "[$(date -Is)] Pulling SonarQube image"

    docker pull sonarqube:lts-community

    echo "[$(date -Is)] Starting SonarQube container"

    docker run -d \
      --name sonarqube \
      --hostname sonarqube \
      --network devops-tools \
      --restart unless-stopped \
      -p 9000:9000 \
      -v sonarqube_data:/opt/sonarqube/data \
      -v sonarqube_extensions:/opt/sonarqube/extensions \
      -v sonarqube_logs:/opt/sonarqube/logs \
      sonarqube:lts-community

    #################################################
    # Nexus Repository container
    #################################################

    if docker ps -a --format '{{.Names}}' | grep -qx nexus; then
      echo "[$(date -Is)] Removing existing Nexus container"
      docker rm -f nexus
    fi

    echo "[$(date -Is)] Pulling Nexus image"

    docker pull sonatype/nexus3:latest

    echo "[$(date -Is)] Starting Nexus container"

    docker run -d \
      --name nexus \
      --hostname nexus \
      --network devops-tools \
      --restart unless-stopped \
      -p 8081:8081 \
      -v nexus_data:/nexus-data \
      sonatype/nexus3:latest

    #################################################
    # Validation
    #################################################

    echo "[$(date -Is)] Running containers"

    docker ps \
      --filter "name=sonarqube" \
      --filter "name=nexus"

    echo "[$(date -Is)] Tools VM bootstrap completed"
  SCRIPT
}

###################################################
# Public IP - GitHub Actions VM
###################################################

resource "azurerm_public_ip" "github_vm" {
  name                = "pip-githubactions-dev-inc-01"
  location            = azurerm_resource_group.github_app.location
  resource_group_name = azurerm_resource_group.github_app.name

  allocation_method = "Static"
  sku               = "Standard"

  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
  }
}

###################################################
# Network Security Group - GitHub Actions VM
###################################################

resource "azurerm_network_security_group" "github_vm" {
  name                = "nsg-githubactions-dev-inc-01"
  location            = azurerm_resource_group.github_app.location
  resource_group_name = azurerm_resource_group.github_app.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
  }
}

###################################################
# NIC - GitHub Actions VM
###################################################

resource "azurerm_network_interface" "github_vm" {
  name                = "nic-githubactions-dev-inc-01"
  location            = azurerm_resource_group.github_app.location
  resource_group_name = azurerm_resource_group.github_app.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.github.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.github_vm.id
  }

  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
  }
}

###################################################
# Associate NSG - GitHub Actions VM
###################################################

resource "azurerm_network_interface_security_group_association" "github_vm" {
  network_interface_id      = azurerm_network_interface.github_vm.id
  network_security_group_id = azurerm_network_security_group.github_vm.id
}

###################################################
# VM - GitHub Actions
###################################################

resource "azurerm_linux_virtual_machine" "github_actions" {
  name                = "vm-githubactions-dev-inc-01"
  location            = azurerm_resource_group.github_app.location
  resource_group_name = azurerm_resource_group.github_app.name

  size = "Standard_D4s_v5"

  admin_username = "hemant"
  admin_password = "Hemant@1234567"

  disable_password_authentication = false

  #################################################
  # Existing scripts/cloudinit.yaml
  #################################################

  custom_data = base64encode(
    data.local_file.github_cloudinit.content
  )

  network_interface_ids = [
    azurerm_network_interface.github_vm.id
  ]

  #################################################
  # Required by az login --identity in cloud-init
  #################################################

  identity {
    type = "SystemAssigned"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    name                 = "osdisk-githubactions-dev-inc-01"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
  }

  depends_on = [
    azurerm_network_interface_security_group_association.github_vm
  ]
}

###################################################
# Key Vault Access - GitHub Actions VM
###################################################

resource "azurerm_role_assignment" "github_vm_keyvault_secrets_user" {
  scope                = data.azurerm_key_vault.github.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.github_actions.identity[0].principal_id
}

###################################################
# Install Trivy - GitHub Actions VM
###################################################

resource "azurerm_virtual_machine_extension" "github_vm_trivy" {
  name                       = "install-trivy"
  virtual_machine_id         = azurerm_linux_virtual_machine.github_actions.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    commandToExecute = "echo '${base64encode(local.install_trivy_script)}' | base64 -d > /tmp/install-trivy.sh && chmod 700 /tmp/install-trivy.sh && /tmp/install-trivy.sh"
  })

  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
    Tool        = "Trivy"
  }

  depends_on = [
    azurerm_role_assignment.github_vm_keyvault_secrets_user
  ]
}

###################################################
# Public IP - Tools VM
###################################################

resource "azurerm_public_ip" "tools_vm" {
  name                = "pip-tools-dev-sa-01"
  location            = azurerm_resource_group.k8s_app.location
  resource_group_name = azurerm_resource_group.k8s_app.name

  allocation_method = "Static"
  sku               = "Standard"

  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }
}

###################################################
# Network Security Group - Tools VM
###################################################

resource "azurerm_network_security_group" "tools_vm" {
  name                = "nsg-tools-dev-sa-01"
  location            = azurerm_resource_group.k8s_app.location
  resource_group_name = azurerm_resource_group.k8s_app.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SonarQube"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Nexus"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8081"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }
}

###################################################
# NIC - Tools VM
###################################################

resource "azurerm_network_interface" "tools_vm" {
  name                = "nic-tools-dev-sa-01"
  location            = azurerm_resource_group.k8s_app.location
  resource_group_name = azurerm_resource_group.k8s_app.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.k8sapp.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tools_vm.id
  }

  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }
}

###################################################
# Associate NSG - Tools VM
###################################################

resource "azurerm_network_interface_security_group_association" "tools_vm" {
  network_interface_id      = azurerm_network_interface.tools_vm.id
  network_security_group_id = azurerm_network_security_group.tools_vm.id
}

###################################################
# VM - Tools
###################################################

resource "azurerm_linux_virtual_machine" "tools" {
  name                = "vm-tools-dev-sa-01"
  location            = azurerm_resource_group.k8s_app.location
  resource_group_name = azurerm_resource_group.k8s_app.name

  size = "Standard_D4s_v5"

  admin_username = "hemant"
  admin_password = "Hemant@1234567"

  disable_password_authentication = false

  #################################################
  # No GitHub runner cloud-init on this VM
  #################################################

  network_interface_ids = [
    azurerm_network_interface.tools_vm.id
  ]

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    name                 = "osdisk-tools-dev-sa-01"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }

  depends_on = [
    azurerm_network_interface_security_group_association.tools_vm
  ]
}

###################################################
# Install Docker, SonarQube and Nexus - Tools VM
###################################################

resource "azurerm_virtual_machine_extension" "tools_vm_bootstrap" {
  name                       = "install-devops-tools"
  virtual_machine_id         = azurerm_linux_virtual_machine.tools.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    commandToExecute = "echo '${base64encode(local.install_tools_script)}' | base64 -d > /tmp/install-tools.sh && chmod 700 /tmp/install-tools.sh && /tmp/install-tools.sh"
  })

  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }
}
