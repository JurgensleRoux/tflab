output "acr_name" {
  description = "Registry name, used by the app pipeline."
  value       = azurerm_container_registry.this.name
}

output "container_app_name" {
  value = azurerm_container_app.app.name
}

output "resource_group_name" {
  value = data.azurerm_resource_group.this.name
}

output "app_url" {
  value = "https://${azurerm_container_app.app.ingress[0].fqdn}"
}