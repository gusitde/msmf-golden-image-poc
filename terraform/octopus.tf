###############################################################################
# MS Migration Factory - Golden Image Prep
# STAGE 3: Octopus Deploy - environments, lifecycle, project, project
#          variables, deployment process (IIS web app), and deployment-target
#          registration.
#
# PROVIDER PLUMBING IS SHARED (do NOT redeclare it here):
#   * The Network stage's providers.tf already declares the `octopusdeploy`
#     provider (source "OctopusDeployLabs/octopusdeploy") AND the
#     `provider "octopusdeploy"` block. Terraform allows exactly ONE
#     required_providers / provider block per module, so this file only adds
#     resources.
#   * The connection inputs octopus_server_url / octopus_api_key (sensitive) /
#     octopus_space_id are declared ONCE in the shared variables.tf and consumed
#     by providers.tf. This stage's extra inputs are namespaced `octopus_*` in
#     variables.octopus.tf.
#   * RECOMMENDED: the shared range is permissive (>= 0.21, < 2.0). This stage
#     is authored and verified against v0.43.x - pin it (`~> 0.43`) and commit
#     the resulting .terraform.lock.hcl for reproducible builds.
#
# STAGE GATING (var.enable_octopus_stage, default false):
#   EVERY resource and data source in this file carries
#   `count = var.enable_octopus_stage ? 1 : 0` (or an equivalently gated
#   for_each), so a network/compute-only `terraform plan` never touches the
#   octopusdeploy provider and succeeds with the placeholder connection
#   defaults. Flip the flag to true (with real octopus_server_url /
#   TF_VAR_octopus_api_key) to manage this stage. All cross-references below
#   are therefore count-indexed ([0]) and the outputs use one()/try().
#
# CROSS-STAGE CONTRACT with Stage 2b (Compute):
#   * Roles: Compute registers each VM's Tentacle with
#     var.compute_octopus_target_roles (default ["msmf-web","iis-web-server"]).
#     This deployment process targets var.octopus_target_roles
#     (default ["iis-web-server"]) - a subset of the above, so the step selects
#     exactly those VMs. Keep the two in sync.
#   * Environment: SINGLE SOURCE OF TRUTH - the octopus_*_environment_name
#     variables drive BOTH the environments created below AND the Compute
#     stage's self-registration (compute.tf maps the shared env dev/test/prod
#     to var.octopus_dev/test/prod_environment_name, so out of the box a `dev`
#     deployment registers into "Development"). Override with
#     var.compute_octopus_environment only for a non-standard mapping.
#   * Ordering: apply this stage BEFORE the Compute VMs boot - the environments
#     must exist before a Tentacle can `register-with` into them.
###############################################################################

#---------------------------------------------------------------------------
# Data sources (gated - never read unless the stage is enabled)
#---------------------------------------------------------------------------

# The built-in package repository (feeds-builtin). CI pushes the .nupkg here.
data "octopusdeploy_feeds" "builtin" {
  count     = var.enable_octopus_stage ? 1 : 0
  feed_type = "BuiltIn"
}

# Default machine policy - only read when the stage is enabled AND explicit
# deployment-target registration is requested (the self-registration path
# leaves the list empty, so this data source is not evaluated at all).
data "octopusdeploy_machine_policies" "default" {
  count        = var.enable_octopus_stage && length(var.octopus_deployment_targets) > 0 ? 1 : 0
  partial_name = var.octopus_machine_policy_name
}

#---------------------------------------------------------------------------
# Environments: Dev -> Test -> Prod
#---------------------------------------------------------------------------

resource "octopusdeploy_environment" "dev" {
  count = var.enable_octopus_stage ? 1 : 0

  name                         = var.octopus_dev_environment_name
  description                  = "MSMF golden-image workloads - Development. Managed by Terraform (project=msmf-golden-image)."
  allow_dynamic_infrastructure = true
  use_guided_failure           = false
  sort_order                   = 10
}

resource "octopusdeploy_environment" "test" {
  count = var.enable_octopus_stage ? 1 : 0

  name                         = var.octopus_test_environment_name
  description                  = "MSMF golden-image workloads - Test. Managed by Terraform (project=msmf-golden-image)."
  allow_dynamic_infrastructure = true
  use_guided_failure           = false
  sort_order                   = 20
}

resource "octopusdeploy_environment" "prod" {
  count = var.enable_octopus_stage ? 1 : 0

  name                         = var.octopus_prod_environment_name
  description                  = "MSMF golden-image workloads - Production. Managed by Terraform (project=msmf-golden-image)."
  allow_dynamic_infrastructure = false
  use_guided_failure           = true
  sort_order                   = 30
}

#---------------------------------------------------------------------------
# Lifecycle: sequential promotion Dev -> Test -> Prod.
#
# WHAT THIS ACTUALLY ENFORCES: each phase lists its environment under
# `optional_deployment_targets` (= deployed on demand, not auto-deployed on
# phase entry) with `minimum_environments_before_promotion = 0`, which in the
# Octopus API means "ALL environments in this phase must have been deployed to
# before the release may enter the next phase". No phase is skippable
# (is_optional_phase = false), so a release must land in Development, then
# Test, before Production is reachable.
#
# WHAT IT DOES NOT ENFORCE: human sign-off. Approval gates live in the
# DEPLOYMENT PROCESS, not the lifecycle - to require them, add a
# "Octopus.Manual" (manual intervention) step scoped to the Test/Production
# environments ahead of the deploy step below, e.g.:
#   step { name = "Approve Production" ... action { action_type =
#     "Octopus.Manual" properties = { "Octopus.Action.Manual.Instructions" =
#     "...", "Octopus.Action.Manual.ResponsibleTeamIds" = "teams-managers" } } }
#---------------------------------------------------------------------------

resource "octopusdeploy_lifecycle" "this" {
  count = var.enable_octopus_stage ? 1 : 0

  name        = var.octopus_lifecycle_name
  description = "MSMF golden-image promotion path. Managed by Terraform (project=msmf-golden-image)."

  release_retention_policy {
    quantity_to_keep    = 30
    unit                = "Days"
    should_keep_forever = false
  }

  tentacle_retention_policy {
    quantity_to_keep    = 30
    unit                = "Days"
    should_keep_forever = false
  }

  # minimum_environments_before_promotion = 0 means ALL environments of the
  # phase are required before promotion (see the block comment above).
  phase {
    name                                  = var.octopus_dev_environment_name
    optional_deployment_targets           = [octopusdeploy_environment.dev[0].id]
    minimum_environments_before_promotion = 0
    is_optional_phase                     = false
  }

  phase {
    name                                  = var.octopus_test_environment_name
    optional_deployment_targets           = [octopusdeploy_environment.test[0].id]
    minimum_environments_before_promotion = 0
    is_optional_phase                     = false
  }

  phase {
    name                                  = var.octopus_prod_environment_name
    optional_deployment_targets           = [octopusdeploy_environment.prod[0].id]
    minimum_environments_before_promotion = 0
    is_optional_phase                     = false
  }
}

#---------------------------------------------------------------------------
# Project group + project
#---------------------------------------------------------------------------

resource "octopusdeploy_project_group" "this" {
  count = var.enable_octopus_stage ? 1 : 0

  name        = var.octopus_project_group_name
  description = "MS Migration Factory - golden-image migration workloads."
}

resource "octopusdeploy_project" "this" {
  count = var.enable_octopus_stage ? 1 : 0

  name                              = var.octopus_project_name
  description                       = "Deploys the migrated IIS web application to golden-image VMs. Managed by Terraform (project=msmf-golden-image)."
  lifecycle_id                      = octopusdeploy_lifecycle.this[0].id
  project_group_id                  = octopusdeploy_project_group.this[0].id
  tenanted_deployment_participation = "Untenanted"
}

#---------------------------------------------------------------------------
# Project variables
#   * MSMF.IIS.* drive the IIS deployment step (#{...} references below).
#   * "Msmf:Environment" is scoped per environment and applied to
#     appsettings.json by the JSON-configuration-variables feature, so the same
#     release visibly renders different config as it is promoted.
#---------------------------------------------------------------------------

resource "octopusdeploy_variable" "iis_website_name" {
  count = var.enable_octopus_stage ? 1 : 0

  owner_id    = octopusdeploy_project.this[0].id
  name        = "MSMF.IIS.WebSiteName"
  type        = "String"
  value       = var.octopus_iis_website_name
  description = "IIS website name created/updated by the deployment."
}

resource "octopusdeploy_variable" "iis_app_pool_name" {
  count = var.enable_octopus_stage ? 1 : 0

  owner_id    = octopusdeploy_project.this[0].id
  name        = "MSMF.IIS.ApplicationPoolName"
  type        = "String"
  value       = var.octopus_iis_app_pool_name
  description = "IIS application pool name."
}

resource "octopusdeploy_variable" "iis_binding_port" {
  count = var.enable_octopus_stage ? 1 : 0

  owner_id    = octopusdeploy_project.this[0].id
  name        = "MSMF.IIS.BindingPort"
  type        = "String"
  value       = var.octopus_iis_binding_port
  description = "HTTP binding port for the IIS website."
}

# Same variable name, different value per environment. Octopus snapshots the
# correct value into each release/phase automatically.
resource "octopusdeploy_variable" "environment_name_dev" {
  count = var.enable_octopus_stage ? 1 : 0

  owner_id = octopusdeploy_project.this[0].id
  name     = "Msmf:Environment"
  type     = "String"
  value    = var.octopus_dev_environment_name

  scope {
    environments = [octopusdeploy_environment.dev[0].id]
  }
}

resource "octopusdeploy_variable" "environment_name_test" {
  count = var.enable_octopus_stage ? 1 : 0

  owner_id = octopusdeploy_project.this[0].id
  name     = "Msmf:Environment"
  type     = "String"
  value    = var.octopus_test_environment_name

  scope {
    environments = [octopusdeploy_environment.test[0].id]
  }
}

resource "octopusdeploy_variable" "environment_name_prod" {
  count = var.enable_octopus_stage ? 1 : 0

  owner_id = octopusdeploy_project.this[0].id
  name     = "Msmf:Environment"
  type     = "String"
  value    = var.octopus_prod_environment_name

  scope {
    environments = [octopusdeploy_environment.prod[0].id]
  }
}

#---------------------------------------------------------------------------
# Deployment process - deploy the IIS web-app package to the target role(s).
# Built-in "Deploy a Package" action (Octopus.TentaclePackage) with the IIS Web
# Site feature and JSON configuration variables feature enabled.
#---------------------------------------------------------------------------

resource "octopusdeploy_deployment_process" "this" {
  count = var.enable_octopus_stage ? 1 : 0

  project_id = octopusdeploy_project.this[0].id

  step {
    name                = "Deploy IIS Web App"
    condition           = "Success"
    package_requirement = "LetOctopusDecide"
    start_trigger       = "StartAfterPrevious"

    # Machines carrying any of these roles receive the deployment. The golden-
    # image Tentacles register with these roles - via Stage 2b self-registration
    # or via the deployment-target resources below.
    target_roles = var.octopus_target_roles

    action {
      name          = "Deploy IIS Web App"
      action_type   = "Octopus.TentaclePackage"
      run_on_server = false
      is_required   = true

      primary_package {
        package_id           = var.octopus_package_id
        feed_id              = data.octopusdeploy_feeds.builtin[0].feeds[0].id
        acquisition_location = "Server"
      }

      properties = {
        # ---- Package handling / configuration replacement -------------------
        "Octopus.Action.Package.DownloadOnTentacle"                = "False"
        "Octopus.Action.EnabledFeatures"                           = "Octopus.Features.IISWebSite,Octopus.Features.JsonConfigurationVariables"
        "Octopus.Action.Package.JsonConfigurationVariablesEnabled" = "True"
        "Octopus.Action.Package.JsonConfigurationVariablesTargets" = "appsettings.json"

        # ---- IIS Web Site feature ------------------------------------------
        "Octopus.Action.IISWebSite.DeploymentType"                = "webSite"
        "Octopus.Action.IISWebSite.CreateOrUpdateWebSite"         = "True"
        "Octopus.Action.IISWebSite.WebSiteName"                   = "#{MSMF.IIS.WebSiteName}"
        "Octopus.Action.IISWebSite.StartWebSite"                  = "True"
        "Octopus.Action.IISWebSite.WebRootType"                   = "packageRoot"
        "Octopus.Action.IISWebSite.EnableAnonymousAuthentication" = "True"
        "Octopus.Action.IISWebSite.EnableBasicAuthentication"     = "False"
        "Octopus.Action.IISWebSite.EnableWindowsAuthentication"   = "False"

        # ---- Application pool ----------------------------------------------
        "Octopus.Action.IISWebSite.ApplicationPoolName" = "#{MSMF.IIS.ApplicationPoolName}"
        # ASP.NET Core is served through the native ASP.NET Core Module (ANCM);
        # "v4.0" is a valid pool CLR value and works with ANCM. Switch the pool
        # to "No Managed Code" post-deploy if you want the strict default.
        "Octopus.Action.IISWebSite.ApplicationPoolFrameworkVersion" = "v4.0"
        "Octopus.Action.IISWebSite.ApplicationPoolIdentityType"     = "ApplicationPoolIdentity"
        "Octopus.Action.IISWebSite.StartApplicationPool"            = "True"

        # ---- Bindings (HTTP on the configured port) ------------------------
        # #{MSMF.IIS.BindingPort} is substituted by Octopus at deploy time.
        "Octopus.Action.IISWebSite.Bindings" = jsonencode([
          {
            protocol            = "http"
            ipAddress           = "*"
            port                = "#{MSMF.IIS.BindingPort}"
            host                = ""
            thumbprint          = null
            certificateVariable = null
            requireSni          = "False"
            enabled             = "True"
          }
        ])
      }
    }
  }
}

#---------------------------------------------------------------------------
# Deployment target registration (mapping deployed VMs -> Octopus)
#
# PRIMARY / RECOMMENDED - SELF-REGISTRATION (leave octopus_deployment_targets
# empty, the default). Stage 2b boots each VM and runs the Stage 1
# install-octopus-tentacle.ps1 `register-with`, which creates the target in
# Octopus with the correct role(s) + environment. This works for BOTH comms
# styles and is the natural fit for golden images, where each VM generates its
# own Tentacle certificate at first boot:
#
#   # Polling (Stage 2b default; target dials out to :10943 - cloud-friendly):
#   Tentacle.exe register-with --server $env:OCTOPUS_URL --apiKey $env:OCTOPUS_APIKEY `
#     --space "Default" --environment "Development" --role "iis-web-server" `
#     --comms-style TentacleActive --console
#
#   # Listening (server dials in to :10933):
#   Tentacle.exe register-with --server $env:OCTOPUS_URL --apiKey $env:OCTOPUS_APIKEY `
#     --space "Default" --environment "Development" --role "iis-web-server" `
#     --comms-style TentaclePassive --console
#
# OPTIONAL - EXPLICIT REGISTRATION via this provider (fixed fleet, thumbprints
# known up-front). Populate octopus_deployment_targets; each entry becomes a
# Polling or Listening target, tagged by role + environment.
#---------------------------------------------------------------------------

locals {
  # Friendly environment name -> Octopus environment ID. one([*]) is used so
  # the expression is reference-safe when the stage is gated off (count = 0);
  # the map is simply empty in that case.
  octopus_environment_ids = var.enable_octopus_stage ? {
    (var.octopus_dev_environment_name)  = one(octopusdeploy_environment.dev[*].id)
    (var.octopus_test_environment_name) = one(octopusdeploy_environment.test[*].id)
    (var.octopus_prod_environment_name) = one(octopusdeploy_environment.prod[*].id)
  } : {}

  # Explicit-registration target maps - forced empty when the stage is
  # disabled so the gated resources below plan to zero instances.
  octopus_polling_targets = {
    for t in var.octopus_deployment_targets : t.name => t
    if var.enable_octopus_stage && lower(t.comms_style) == "polling"
  }

  octopus_listening_targets = {
    for t in var.octopus_deployment_targets : t.name => t
    if var.enable_octopus_stage && lower(t.comms_style) == "listening"
  }
}

# Polling Tentacle targets (Stage 2b default). tentacle_url is the polling
# subscription URL, e.g. poll://a1b2c3d4e5f6g7h8/.
resource "octopusdeploy_polling_tentacle_deployment_target" "vm" {
  for_each = local.octopus_polling_targets

  name                              = each.value.name
  roles                             = each.value.roles != null ? each.value.roles : var.octopus_target_roles
  environments                      = [local.octopus_environment_ids[each.value.environment]]
  tentacle_url                      = each.value.tentacle_url
  thumbprint                        = each.value.thumbprint
  machine_policy_id                 = data.octopusdeploy_machine_policies.default[0].machine_policies[0].id
  tenanted_deployment_participation = "Untenanted"
  is_disabled                       = false
}

# Listening Tentacle targets. tentacle_url is https://<host-or-ip>:10933/.
resource "octopusdeploy_listening_tentacle_deployment_target" "vm" {
  for_each = local.octopus_listening_targets

  name                              = each.value.name
  roles                             = each.value.roles != null ? each.value.roles : var.octopus_target_roles
  environments                      = [local.octopus_environment_ids[each.value.environment]]
  tentacle_url                      = each.value.tentacle_url
  thumbprint                        = each.value.thumbprint
  machine_policy_id                 = data.octopusdeploy_machine_policies.default[0].machine_policies[0].id
  tenanted_deployment_participation = "Untenanted"
  is_disabled                       = false
}
