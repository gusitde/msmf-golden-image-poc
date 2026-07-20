###############################################################################
# STAGE 3 (Octopus) - outputs. Namespaced `octopus_*`; merge into the shared
# outputs.tf. CI reads these (project name/id, target roles) to wire releases.
#
# All Octopus resources are gated on var.enable_octopus_stage (count = 0 when
# disabled), so every output below is reference-safe via one()/try() and
# simply returns null / an empty map while the stage is off.
###############################################################################

output "octopus_project_id" {
  description = "ID of the MSMF Octopus project (null while enable_octopus_stage = false)."
  value       = one(octopusdeploy_project.this[*].id)
}

output "octopus_project_name" {
  description = "Name of the MSMF Octopus project (pass to `octopus release create --project`; null while enable_octopus_stage = false)."
  value       = one(octopusdeploy_project.this[*].name)
}

output "octopus_lifecycle_id" {
  description = "ID of the sequential Dev -> Test -> Prod lifecycle (null while enable_octopus_stage = false)."
  value       = one(octopusdeploy_lifecycle.this[*].id)
}

output "octopus_environment_ids" {
  description = "Map of environment name -> Octopus environment ID (empty while enable_octopus_stage = false)."
  value       = local.octopus_environment_ids
}

output "octopus_target_roles" {
  description = "Roles golden-image VMs must register with to receive deployments (see Stage 2b compute_octopus_target_roles)."
  value       = var.octopus_target_roles
}

output "octopus_builtin_feed_id" {
  description = "ID of the built-in package feed CI pushes to (null while enable_octopus_stage = false)."
  value       = try(data.octopusdeploy_feeds.builtin[0].feeds[0].id, null)
}

output "octopus_registered_target_ids" {
  description = "IDs of explicitly-registered deployment targets (empty when self-registration is used or the stage is disabled)."
  value = merge(
    { for k, t in octopusdeploy_polling_tentacle_deployment_target.vm : k => t.id },
    { for k, t in octopusdeploy_listening_tentacle_deployment_target.vm : k => t.id },
  )
}
