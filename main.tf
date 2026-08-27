###################################################
# Local Bootstrap Script - Tools VM
###################################################

locals {
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

    #################################################
    # Install Docker
    #################################################

    if ! command -v docker >/dev/null 2>&1; then
      echo "[$(date -Is)] Installing Docker"

      curl -fsSL https://get.docker.com | sh
    else
      echo "[$(date -Is)] Docker is already installed"
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
    # Configure host requirements for SonarQube
    #################################################

    sysctl -w vm.max_map_count=524288
    sysctl -w fs.file-max=131072

    cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
    vm.max_map_count=524288
    fs.file-max=131072
    EOF

    #################################################
    # Create Docker network
    #################################################

    if ! docker network inspect devops-tools >/dev/null 2>&1; then
      echo "[$(date -Is)] Creating Docker network: devops-tools"

      docker network create devops-tools
    else
      echo "[$(date -Is)] Docker network devops-tools already exists"
    fi

    #################################################
    # Deploy SonarQube container
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
    # Deploy Nexus Repository container
    #################################################

    if docker ps -a --format '{{.Names}}' | grep -qx nexus; then
      echo "[$(date -Is)] Removing existing Nexus container"

      docker rm -f nexus
    fi

    echo "[$(date -Is)] Pulling Nexus Repository image"

    docker pull sonatype/nexus3:latest

    echo "[$(date -Is)] Starting Nexus Repository container"

    docker run -d \
      --name nexus \
      --hostname nexus \
      --network devops-tools \
      --restart unless-stopped \
      -p 8081:8081 \
      -v nexus_data:/nexus-data \
      sonatype/nexus3:latest

    #################################################
    # Validate running containers
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
  location            = data.azurerm_resource_group.github_app.location
  resource_group_name = data.azurerm_resource_group.github_app.name

  allocation_method = "Static"
  sku               = "Standard"

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
  location            = data.azurerm_resource_group.github_app.location
  resource_group_name = data.azurerm_resource_group.github_app.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = "snet-github-dev-inc-01"
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.github_vm.id
  }

  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
  }
}

###################################################
# VM - GitHub Actions
###################################################

resource "azurerm_linux_virtual_machine" "github_actions" {
  name                = "vm-githubactions-dev-inc-01"
  location            = data.azurerm_resource_group.github_app.location
  resource_group_name = data.azurerm_resource_group.github_app.name

  size = "Standard_D4s_v5"

  admin_username = "hemant"
  admin_password = "Hemant@1234567"

  disable_password_authentication = false

  custom_data = base64encode(
    data.local_file.github_cloudinit.content
  )

  network_interface_ids = [
    azurerm_network_interface.github_vm.id
  ]

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
# Public IP - Tools VM
###################################################

resource "azurerm_public_ip" "tools_vm" {
  name                = "pip-tools-dev-sa-01"
  location            = data.azurerm_resource_group.k8s_app.location
  resource_group_name = data.azurerm_resource_group.k8s_app.name

  allocation_method = "Static"
  sku               = "Standard"

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
  location            = data.azurerm_resource_group.k8s_app.location
  resource_group_name = data.azurerm_resource_group.k8s_app.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = "snet-k8sapp-dev-sa-01"
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tools_vm.id
  }

  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }
}

###################################################
# VM - Tools
###################################################

resource "azurerm_linux_virtual_machine" "tools" {
  name                = "vm-tools-dev-sa-01"
  location            = data.azurerm_resource_group.k8s_app.location
  resource_group_name = data.azurerm_resource_group.k8s_app.name

  size = "Standard_D4s_v5"

  admin_username = "hemant"
  admin_password = "Hemant@1234567"

  disable_password_authentication = false

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
