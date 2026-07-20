###############################################################################
# STAGE 3 (Octopus) - input variables.
#
# NOTE: the Octopus CONNECTION inputs (octopus_server_url, octopus_api_key
# [sensitive], octopus_space_id) are declared ONCE in the SHARED variables.tf
# (consumed by providers.tf) and are intentionally NOT redeclared here - a
# Terraform variable may be declared only once per module.
#
# Everything below is namespaced `octopus_*` and owned by this stage.
###############################################################################

variable "octopus_project_name" {
  description = "Octopus project name."
  type        = string
  default     = "MSMF Golden Image App"
}

variable "octopus_project_group_name" {
  description = "Octopus project group name."
  type        = string
  default     = "MS Migration Factory"
}

variable "octopus_lifecycle_name" {
  description = "Octopus lifecycle name (gated Dev -> Test -> Prod)."
  type        = string
  default     = "MSMF Dev-Test-Prod"
}

variable "octopus_dev_environment_name" {
  description = "Development environment name. Stage 2b's compute_octopus_environment must match this to self-register Dev VMs here."
  type        = string
  default     = "Development"
}

variable "octopus_test_environment_name" {
  description = "Test environment name."
  type        = string
  default     = "Test"
}

variable "octopus_prod_environment_name" {
  description = "Production environment name."
  type        = string
  default     = "Production"
}

variable "octopus_package_id" {
  description = "Package ID published by CI to the built-in feed and deployed to IIS."
  type        = string
  default     = "MSMF.GoldenImage.WebApp"
}

variable "octopus_target_roles" {
  description = <<-EOT
    Role(s) the deployment step targets. Must be a SUBSET of Stage 2b's
    var.compute_octopus_target_roles (default ["msmf-web","iis-web-server"]) so
    the self-registered VMs are selected by this process.
  EOT
  type    = list(string)
  default = ["iis-web-server"]

  validation {
    condition     = length(var.octopus_target_roles) >= 1
    error_message = "Provide at least one target role."
  }
}

variable "octopus_iis_website_name" {
  description = "IIS website name created/updated on the target VMs."
  type        = string
  default     = "MSMFGoldenImageApp"
}

variable "octopus_iis_app_pool_name" {
  description = "IIS application pool name."
  type        = string
  default     = "MSMFGoldenImageApp"
}

variable "octopus_iis_binding_port" {
  description = "HTTP binding port for the IIS website."
  type        = string
  default     = "80"
}

variable "octopus_machine_policy_name" {
  description = "Machine policy applied to explicitly-registered deployment targets."
  type        = string
  default     = "Default Machine Policy"
}

variable "octopus_deployment_targets" {
  description = <<-EOT
    Explicit Tentacle deployment targets to register. Leave empty ([]) to rely
    on Stage 2b Tentacle self-registration instead (recommended for golden
    images). Per target:
      * comms_style  - "Polling" (default, matches Stage 2b) or "Listening".
      * tentacle_url - Polling: poll://<subscription-id>/  Listening: https://<host>:10933/
      * thumbprint   - the VM Tentacle's certificate thumbprint.
      * environment  - must match one of the environment names above.
      * roles        - defaults to var.octopus_target_roles when omitted.
  EOT
  type = list(object({
    name         = string
    comms_style  = optional(string, "Polling")
    tentacle_url = string
    thumbprint   = string
    environment  = string
    roles        = optional(list(string))
  }))
  default = []

  validation {
    condition = alltrue([
      for t in var.octopus_deployment_targets :
      contains(["polling", "listening"], lower(t.comms_style))
    ])
    error_message = "Each octopus_deployment_targets[*].comms_style must be \"Polling\" or \"Listening\"."
  }

  validation {
    condition = alltrue([
      for t in var.octopus_deployment_targets :
      contains([
        var.octopus_dev_environment_name,
        var.octopus_test_environment_name,
        var.octopus_prod_environment_name,
      ], t.environment)
    ])
    error_message = "Each octopus_deployment_targets[*].environment must be one of the configured environment names."
  }
}
