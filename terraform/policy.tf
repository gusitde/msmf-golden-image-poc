###############################################################################
# policy.tf  --  MSMF Golden-Image PoC | Stage 2c (Policy)
#
# The security-compliance baseline, assigned via Azure Policy at
# the WORKLOAD RESOURCE-GROUP scope (module.resource_group, network.tf).
#
# TWO LAYERS:
#   A) A RECOGNIZED built-in Azure Policy INITIATIVE (var.compliance_initiative;
#      default = Microsoft Cloud Security Benchmark) — the audit-recognized
#      standard the customer's compliance baseline maps to. Assigned with a system-
#      assigned identity + a Contributor role grant so its DeployIfNotExists /
#      Modify controls can remediate. Swap to CIS / NIST / ISO 27001 by variable.
#   B) TARGETED DENY CONTROLS (below) that give the baseline enforcement TEETH
#      the audit-only initiative does not: deny untagged / out-of-region / public-
#      IP resources at create time.
# Replace layer A's initiative (or add specific controls to layer B) with the
# exact the security-compliance control set when the customer supplies it.
#
# Controls (all BUILT-IN policy definitions, resolved by display name so the
# well-known definition IDs never have to be hard-coded):
#   1. Require tags            -- one assignment per key in
#                                 var.policy_required_tag_keys (project/env/
#                                 owner by default). Effect: Deny.
#   2. Allowed locations       -- restrict resource regions to
#                                 var.policy_allowed_locations. Effect: Deny.
#   3. Deny public IPs on NICs -- gated by var.policy_deny_public_ip (opt OUT,
#                                 not opt in). Effect: Deny.
#   4. NSG on every subnet     -- built-in control. Effect: AuditIfNotExists
#                                 (the built-in has no deny variant; network.tf
#                                 already associates an NSG with each subnet,
#                                 so this control PROVES compliance).
#   5. Disk encryption         -- gated by var.policy_require_disk_encryption.
#                                 Effect: AuditIfNotExists (see variable docs).
#
# ENFORCEMENT: var.policy_enforcement_mode defaults to "Default" (ENFORCED --
# deny effects actually block non-compliant creates). Relax to "DoNotEnforce"
# for an audit-only dry run. The azurerm assignment resource models this as
# `enforce = true|false`, mapped from the variable below.
#
# NO `identity` BLOCKS on the assignments (linters may flag this): a managed
# identity is only required for DeployIfNotExists/Modify remediation policies.
# Every control here is Deny or AuditIfNotExists, which evaluate without one.
#
# NOTE ON AVM: Azure Policy assignment has no lightweight AVM resource module
# (the ALZ pattern module Azure/avm-ptn-alz is management-group scale); for a
# resource-group-scoped baseline, raw azurerm assignments per control are the
# deliberate, documented fallback -- same rationale as azurerm_image in
# compute.tf.
###############################################################################

#-----------------------------------------------------------------------------#
# Locals (namespaced `policy_*` to avoid collisions with other stages' locals)
#-----------------------------------------------------------------------------#
locals {
  # azurerm models enforcement as a bool: true = "Default", false = "DoNotEnforce".
  policy_enforce = var.policy_enforcement_mode == "Default"

  # RG-scoped policy assignment names must be <= 64 chars; keep them short and
  # deterministic.
  policy_scope_id = module.resource_group.resource_id

  # Recognized built-in Policy INITIATIVE (policySetDefinition) GUIDs the compliance baseline
  # baseline maps to. These are stable Azure built-ins; the data source below
  # validates the chosen one exists at plan time.
  compliance_initiative_ids = {
    mcsb     = "1f3afdf9-d0c9-4c3d-847f-89da613e70a8" # Microsoft cloud security benchmark
    cis      = "06f19060-9e68-4070-92ca-f15cc126059e" # CIS Microsoft Azure Foundations Benchmark v2.0.0
    nist     = "179d1daa-458f-4e47-8086-2a68d0d6c38f" # NIST SP 800-53 Rev. 5
    iso27001 = "89c6cddc-1c73-4ac1-b19c-54d1a15a42f2" # ISO 27001:2013
  }
  compliance_enabled = var.compliance_initiative != "none"
  compliance_set_id  = lookup(local.compliance_initiative_ids, var.compliance_initiative, null)
}

#-----------------------------------------------------------------------------#
# Built-in policy definition lookups.
# Looked up by their canonical, immutable built-in GUID (`name`) -- more
# robust than display-name matching, which is exact-match and has broken on
# punctuation changes before. The current display name is kept as a comment
# for the human reader; the data source validates the definition exists at
# plan time and yields the full /providers/Microsoft.Authorization/
# policyDefinitions/<guid> resource id.
#-----------------------------------------------------------------------------#

# "Require a tag on resources"
data "azurerm_policy_definition" "require_tag" {
  name = "871b6d14-10aa-478d-b590-94f262ecfa99"
}

# "Allowed locations"
data "azurerm_policy_definition" "allowed_locations" {
  name = "e56962a6-4747-49cd-b67b-bf8b01975c4c"
}

# "Network interfaces should not have public IPs"
data "azurerm_policy_definition" "deny_nic_public_ip" {
  count = var.policy_deny_public_ip ? 1 : 0
  name  = "83a86a26-fd1f-447c-b59d-e51f44264114"
}

# "Subnets should be associated with a Network Security Group"
data "azurerm_policy_definition" "subnet_nsg" {
  name = "e71308d3-144b-4262-b144-efdc3cc90517"
}

# "Windows virtual machines should enable Azure Disk Encryption or EncryptionAtHost."
data "azurerm_policy_definition" "disk_encryption" {
  count = var.policy_require_disk_encryption ? 1 : 0
  name  = "3dc5edcd-002d-444c-b216-e123bbfa37c0"
}

#-----------------------------------------------------------------------------#
# LAYER A) Recognized built-in initiative (MCSB / CIS / NIST / ISO 27001).
# This is the audit-recognized standard the the security-compliance baseline maps to.
# It carries Audit + AuditIfNotExists + DeployIfNotExists controls, so the
# assignment needs a system-assigned identity and (for remediation to run) a
# Contributor grant on the workload RG.
#-----------------------------------------------------------------------------#
data "azurerm_policy_set_definition" "recognized" {
  count = local.compliance_enabled ? 1 : 0
  name  = local.compliance_set_id
}

resource "azurerm_resource_group_policy_assignment" "recognized_baseline" {
  count = local.compliance_enabled ? 1 : 0

  name                 = "msmf-baseline-${var.compliance_initiative}"
  display_name         = "compliance baseline → ${upper(var.compliance_initiative)}: ${data.azurerm_policy_set_definition.recognized[0].display_name}"
  description          = "the security-compliance baseline mapped to the recognized built-in initiative '${data.azurerm_policy_set_definition.recognized[0].display_name}', assigned at the workload RG scope. Managed by Terraform (project=msmf-golden-image)."
  resource_group_id    = local.policy_scope_id
  policy_definition_id = data.azurerm_policy_set_definition.recognized[0].id
  enforce              = local.policy_enforce
  location             = var.location

  identity {
    type = "SystemAssigned"
  }
}

# Grant the initiative's managed identity Contributor on the workload RG so its
# DeployIfNotExists / Modify controls can remediate (audit-only controls work
# without this; remediation tasks require it).
resource "azurerm_role_assignment" "recognized_baseline_remediation" {
  count = local.compliance_enabled ? 1 : 0

  scope                = local.policy_scope_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_resource_group_policy_assignment.recognized_baseline[0].identity[0].principal_id
}

#-----------------------------------------------------------------------------#
# LAYER B) Targeted DENY controls (enforcement teeth).
# 1) Require tags -- one assignment per required key (project/env/owner).
#-----------------------------------------------------------------------------#
resource "azurerm_resource_group_policy_assignment" "require_tags" {
  for_each = toset(var.policy_required_tag_keys)

  name                 = "msmf-require-tag-${each.value}"
  display_name         = "MSMF baseline: require tag '${each.value}'"
  description          = "Denies resource creation in the workload RG without the '${each.value}' tag. Managed by Terraform (project=msmf-golden-image)."
  resource_group_id    = local.policy_scope_id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  enforce              = local.policy_enforce

  parameters = jsonencode({
    tagName = { value = each.value }
  })
}

#-----------------------------------------------------------------------------#
# 2) Allowed locations.
#-----------------------------------------------------------------------------#
resource "azurerm_resource_group_policy_assignment" "allowed_locations" {
  name                 = "msmf-allowed-locations"
  display_name         = "MSMF baseline: allowed locations"
  description          = "Restricts resources in the workload RG to approved regions. Managed by Terraform (project=msmf-golden-image)."
  resource_group_id    = local.policy_scope_id
  policy_definition_id = data.azurerm_policy_definition.allowed_locations.id
  enforce              = local.policy_enforce

  parameters = jsonencode({
    listOfAllowedLocations = { value = var.policy_allowed_locations }
  })
}

#-----------------------------------------------------------------------------#
# 3) Deny public IPs on network interfaces (opt-out via policy_deny_public_ip).
#    If you must run Listening Tentacles with compute_enable_public_ip = true,
#    set policy_deny_public_ip = false -- the flag exists precisely so the
#    exception is an explicit, reviewable tfvars line.
#-----------------------------------------------------------------------------#
resource "azurerm_resource_group_policy_assignment" "deny_nic_public_ip" {
  count = var.policy_deny_public_ip ? 1 : 0

  name                 = "msmf-deny-nic-public-ip"
  display_name         = "MSMF baseline: deny public IPs on NICs"
  description          = "Denies network interfaces with attached public IP addresses in the workload RG. Managed by Terraform (project=msmf-golden-image)."
  resource_group_id    = local.policy_scope_id
  policy_definition_id = data.azurerm_policy_definition.deny_nic_public_ip[0].id
  enforce              = local.policy_enforce
}

#-----------------------------------------------------------------------------#
# 4) NSG required on every subnet (AuditIfNotExists -- built-in offers no deny).
#-----------------------------------------------------------------------------#
resource "azurerm_resource_group_policy_assignment" "subnet_nsg" {
  name                 = "msmf-require-subnet-nsg"
  display_name         = "MSMF baseline: NSG on every subnet"
  description          = "Audits subnets in the workload RG that are not associated with a Network Security Group. Managed by Terraform (project=msmf-golden-image)."
  resource_group_id    = local.policy_scope_id
  policy_definition_id = data.azurerm_policy_definition.subnet_nsg.id
  enforce              = local.policy_enforce
}

#-----------------------------------------------------------------------------#
# 5) Disk-encryption audit (opt-out via policy_require_disk_encryption).
#-----------------------------------------------------------------------------#
resource "azurerm_resource_group_policy_assignment" "disk_encryption" {
  count = var.policy_require_disk_encryption ? 1 : 0

  name                 = "msmf-audit-disk-encryption"
  display_name         = "MSMF baseline: audit VM disk encryption"
  description          = "Audits Windows VMs in the workload RG without Azure Disk Encryption or EncryptionAtHost. Managed by Terraform (project=msmf-golden-image)."
  resource_group_id    = local.policy_scope_id
  policy_definition_id = data.azurerm_policy_definition.disk_encryption[0].id
  enforce              = local.policy_enforce
}

###############################################################################
# Outputs -- policy-scoped, for compliance reporting / demo verification.
###############################################################################

output "policy_assignment_ids" {
  description = "Map of control name -> policy assignment id for the compliance baseline."
  value = merge(
    { for k, a in azurerm_resource_group_policy_assignment.require_tags : "require-tag-${k}" => a.id },
    { "allowed-locations" = azurerm_resource_group_policy_assignment.allowed_locations.id },
    { "subnet-nsg" = azurerm_resource_group_policy_assignment.subnet_nsg.id },
    { for a in azurerm_resource_group_policy_assignment.deny_nic_public_ip : "deny-nic-public-ip" => a.id },
    { for a in azurerm_resource_group_policy_assignment.disk_encryption : "audit-disk-encryption" => a.id },
  )
}

output "policy_enforcement_mode" {
  description = "Effective enforcement mode of the compliance baseline (Default = enforced, DoNotEnforce = audit-only)."
  value       = var.policy_enforcement_mode
}

output "compliance_initiative" {
  description = "The recognized built-in initiative the compliance baseline maps to (or 'none'), and its assignment id."
  value = {
    selected      = var.compliance_initiative
    display_name  = local.compliance_enabled ? data.azurerm_policy_set_definition.recognized[0].display_name : null
    assignment_id = local.compliance_enabled ? azurerm_resource_group_policy_assignment.recognized_baseline[0].id : null
  }
}
