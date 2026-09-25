terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateahdgal"
    container_name       = "tfstate"
    key                  = "tflab.prod.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
}

module "platform" {
  source = "../../modules/platform"

  workload            = "tflab"
  environment         = "prod"
  resource_group_name = "rg-tflab-prod"
  location            = "westeurope"
  min_replicas        = 1
  log_retention_days  = 90
  cost_centre         = "platform"
}

output "acr_name" {
  value = module.platform.acr_name
}

output "app_url" {
  value = module.platform.app_url
}