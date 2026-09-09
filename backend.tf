terraform {
    backend "azurerm" {
        resource_group_name = "rg-tfstate"
        storage_account_name = "sttfstateahdgal"
        container_name = "tfstate"
        key = "tflab.dev.tfstate"
        use_azuread_auth = true
    }
}