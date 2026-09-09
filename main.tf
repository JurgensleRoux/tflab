terraform {
    required_providers {
        azurerm = {
            source = "hashicorp/azurerm"
            version = "~> 4.0"
            }
    }
}

provider "azurerm" {
    features {}
}

resource "azurerm_resource_group" "lab" {
    name = "rg-tflab-dev"
    location = "southafricanorth"

    tags = {
        environment = "lab"
        managed_by = "terraform"
    }
}

resource "random_string" "suffix" {
    length = 6
    special = false
    upper = false
}

resource "azurerm_storage_account" "lab" {
    name = "sttflab${random_string.suffix.result}"
    resource_group_name = azurerm_resource_group.lab.name
    location = azurerm_resource_group.lab.location
    account_tier = "Standard"
    account_replication_type = "LRS"
}

output "storage_account_name" {
    value = azurerm_storage_account.lab.name
}