data "local_file" "github_cloudinit" {
  filename = "${path.module}/cloud-init-github.yaml"
}

data "local_file" "tools_cloudinit" {
  filename = "${path.module}/cloud-init-tools.yaml"
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
  custom_data = base64encode(
    data.local_file.github_cloudinit.content
  )

  network_interface_ids = [
    azurerm_network_interface.github_vm.id
  ]

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }


  tags = {
    Environment = "Dev"
    Workload    = "GitHubActions"
  }
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
  custom_data = base64encode(
    data.local_file.tools_cloudinit.content
  )

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
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }


  tags = {
    Environment = "Dev"
    Workload    = "Tools"
  }
}
