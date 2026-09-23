resource "azurerm_log_analytics_workspace" "lab" {
  name                = "log-tflab-dev"
  resource_group_name = data.azurerm_resource_group.lab.name
  location            = data.azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_container_registry" "lab" {
  name                = "crtflab${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.lab.name
  location            = data.azurerm_resource_group.lab.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.common_tags
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-tflab-app"
  resource_group_name = data.azurerm_resource_group.lab.name
  location            = data.azurerm_resource_group.lab.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.lab.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app_environment" "lab" {
  name                       = "cae-tflab-dev"
  resource_group_name        = data.azurerm_resource_group.lab.name
  location                   = data.azurerm_resource_group.lab.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.lab.id
  tags                       = local.common_tags
}

resource "azurerm_container_app" "app" {
  name                         = "ca-tflab-app"
  container_app_environment_id = azurerm_container_app_environment.lab.id
  resource_group_name          = data.azurerm_resource_group.lab.name
  revision_mode                = "Single"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.lab.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 80
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "app"
      image  = "mcr.microsoft.com/k8se/quickstart:latest" # placeholder until the pipeline ships ours
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image] # the app pipeline owns the image
  }

  depends_on = [azurerm_role_assignment.app_acr_pull]
}

output "acr_name" {
  value = azurerm_container_registry.lab.name
}

output "app_url" {
  value = "https://${azurerm_container_app.app.ingress[0].fqdn}"
}