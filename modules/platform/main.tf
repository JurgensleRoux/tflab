resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  # One place that decides names and region.
  name     = "${var.workload}-${var.environment}"
  suffix   = random_string.suffix.result
  location = coalesce(var.location, data.azurerm_resource_group.this.location)

  tags = {
    Service     = var.workload
    Environment = var.environment
    ManagedBy   = "terraform"
    CostCentre  = var.cost_centre
  }
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

resource "azurerm_container_registry" "this" {
  # Every skip below has one cause: this registry is Basic. Each control
  # Checkov wants is either a Premium-tier feature or a paid Defender plan.
  # A customer platform would run this Premium and none of these would be here.
  #checkov:skip=CKV_AZURE_139:Disabling public network access is Premium-only, and hosted runners push over the internet
  #checkov:skip=CKV_AZURE_163:Vulnerability scanning is Microsoft Defender for Containers, a paid subscription plan
  #checkov:skip=CKV_AZURE_164:Content trust is Premium-only
  #checkov:skip=CKV_AZURE_165:Geo-replication is Premium-only and this platform is single-region
  #checkov:skip=CKV_AZURE_166:Image quarantine is a Premium preview feature
  #checkov:skip=CKV_AZURE_167:Untagged-manifest retention is Premium-only
  #checkov:skip=CKV_AZURE_233:Provider rejects zone_redundancy_enabled on Basic - tested 2026-10-01
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints are Premium-only

  name                = "cr${var.workload}${var.environment}${local.suffix}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.name}-app"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app_environment" "this" {
  count = var.enable_container_app ? 1 : 0

  name                       = "cae-${local.name}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = local.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags
}

resource "azurerm_container_app" "app" {
  count = var.enable_container_app ? 1 : 0

  name                         = "ca-${local.name}-app"
  container_app_environment_id = azurerm_container_app_environment.this[0].id
  resource_group_name          = data.azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
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
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "app"
      image  = "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [azurerm_role_assignment.app_acr_pull]
}
moved {
  from = azurerm_container_app_environment.this
  to   = azurerm_container_app_environment.this[0]
}

moved {
  from = azurerm_container_app.app
  to   = azurerm_container_app.app[0]
}
