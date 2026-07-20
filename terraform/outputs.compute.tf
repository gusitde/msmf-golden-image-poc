###############################################################################
# MS Migration Factory — Golden Image Prep
# Stage 2b : COMPUTE — outputs
# File     : terraform/outputs.compute.tf
#
# Consumed by Stage 3 (Octopus target mapping / CI-CD wiring) and by operators.
# All outputs are namespaced `compute_*`.
###############################################################################

output "compute_vm_names" {
  description = "Map of instance key -> Windows VM name (also the Octopus target/machine name)."
  value       = { for k, m in module.vm : k => m.name }
}

output "compute_vm_resource_ids" {
  description = "Map of instance key -> VM resource id."
  value       = { for k, m in module.vm : k => m.resource_id }
}

output "compute_vm_private_ips" {
  description = "Map of instance key -> primary NIC private IP address."
  value       = { for k, m in module.vm : k => try(values(m.network_interfaces)[0].private_ip_address, null) }
}

output "compute_vm_principal_ids" {
  description = "Map of instance key -> system-assigned managed identity principal id (for RBAC / Key Vault access policies)."
  value       = { for k, m in module.vm : k => m.system_assigned_mi_principal_id }
}

output "compute_vm_nic_ids" {
  description = "Map of instance key -> primary NIC resource id."
  value       = { for k, m in module.vm : k => try(values(m.network_interfaces)[0].id, null) }
}

output "compute_source_image_resource_id" {
  description = "The golden image resource id the VMs were created from (gallery version id or JFrog-derived managed image id)."
  value       = local.compute_source_image_id
}

output "compute_image_source" {
  description = "Which image source was used for this deployment: gallery | jfrog."
  value       = var.image_source
}
