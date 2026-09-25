variable "workload" {
  description = "Short name for the workload. Used in every resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.workload))
    error_message = "workload must be 3-10 lowercase letters or digits (it ends up in a globally unique registry name)."
  }
}

variable "environment" {
  description = "Which instance of the platform this is."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "resource_group_name" {
  description = "Existing resource group to build into. Created by bootstrap, not by Terraform."
  type        = string
}

variable "min_replicas" {
  description = "0 lets the app scale to zero. Production usually wants at least 1."
  type        = number
  default     = 0
}

variable "log_retention_days" {
  description = "How long Log Analytics keeps data."
  type        = number
  default     = 30
}

variable "cost_centre" {
  description = "Tag used for cost allocation."
  type        = string
  default     = "lab"
}

variable "location" {
  description = "Azure region for the platform. Defaults to the resource group's location."
  type        = string
  default     = null
}
variable "enable_container_app" {
  description = "Create the Container Apps environment and app. False where the subscription's Container Apps quota is already spent."
  type        = bool
  default     = true
}
