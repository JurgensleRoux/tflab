data "azurerm_policy_definition" "allowed_locations" {
  display_name = "Allowed locations"
}

resource "azurerm_resource_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  resource_group_id    = data.azurerm_resource_group.this.id
  policy_definition_id = data.azurerm_policy_definition.allowed_locations.id
  enforce              = var.enforce_policy

  parameters = jsonencode({
    listOfAllowedLocations = { value = [local.location] }
  })
}

data "azurerm_policy_definition" "require_tag" {
  display_name = "Require a tag on resources"
}

resource "azurerm_resource_group_policy_assignment" "require_cost_centre" {
  name                 = "require-costcentre"
  resource_group_id    = data.azurerm_resource_group.this.id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  enforce              = var.enforce_policy

  parameters = jsonencode({
    tagName = { value = "CostCentre" }
  })
}
