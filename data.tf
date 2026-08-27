###################################################
# GitHub Actions Runner Cloud-Init
###################################################

data "local_file" "github_cloudinit" {
  filename = "${path.module}/scripts/cloudinit.yaml"
}

###################################################
# Existing GitHub Key Vault
###################################################

data "azurerm_key_vault" "github" {
  name                = "kv-github-dev-inc-01"
  resource_group_name = azurerm_resource_group.github_app.name
}
