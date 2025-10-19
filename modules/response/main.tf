data "google_client_config" "current" {}

# Generate a random suffix for custom roles to avoid conflicts with pending deletion
resource "random_id" "role_suffix" {
  byte_length = 4

  keepers = {
    # Change this value if you need to force recreation of all roles
    role_version = "v1"
  }
}

locals {
  runbook_config_all = yamldecode(file("${path.module}/templates/runbook_config.yaml"))
  runbook_config = {
    Remediations = [
      for remediation in local.runbook_config_all.Remediations :
      remediation if(lookup(remediation, "cloud_provider", "aws") == "gcp")
    ]
  }

  # Get unique remediations with role files for role creation
  remediations_with_roles = {
    for remediation in local.runbook_config.Remediations :
    remediation.name => remediation
    if lookup(remediation, "role_file", null) != null
  }

  # Create a mapping of role files to their full paths
  role_file_paths = {
    "gcp_restart_vm_role.json"                           = "gcp_restart_vm_role.json"
    "gcp_isolated_vm_from_firewall.json"                 = "gcp_isolated_vm_from_firewall.json"
    "gcp_remove_service_account_from_vm.json"            = "gcp_remove_service_account_from_vm.json"
    "vm_mig_detach_policy.json"                          = "vm_mig_detach_policy.json"
    "gcp_vm_create_snapshot_role.json"                   = "gcp_vm_create_snapshot_role.json"
    "gcp_stop_vm_role.json"                              = "gcp_stop_vm_role.json"
    "gcp_enable_versioning_for_storage_bucket_role.json" = "shared/remediation/gcp_roles/gcp_enable_versioning_for_storage_bucket_role.json"
    "gcp_disable_public_access_bucket.json"              = "gcp_disable_public_access_bucket.json"
    "gcp_replace_function_service_account_role.json"     = "gcp_replace_function_service_account_role.json"
    "gcp_remove_iam_role_from_instance.json"             = "shared/gcp_remove_iam_role_from_instance.json"
  }

  # Determine the project where service accounts will be created
  # For org-level: use the first project in the map
  # For project-level: use the actual project
  sa_project = var.org_level_permissions ? values(var.projects)[0].project_id : ""

  # Create a map for workflow to service account mapping
  workflow_sa_map = var.org_level_permissions ? {
    # For org-level: map remediation name to org-level service account
    for item in flatten([
      for project_key, project_value in var.projects : [
        for remediation in local.runbook_config.Remediations : {
          key              = "${project_key}_${remediation.name}"
          remediation_name = remediation.name
          has_role_file    = lookup(remediation, "role_file", null) != null
        }
      ]
    ]) : item.key => item.has_role_file ? google_service_account.remediation_sa_org[item.remediation_name].email : null
    } : {
    # For project-level: direct mapping to project-level service account
    for item in flatten([
      for project_key, project_value in var.projects : [
        for remediation in local.runbook_config.Remediations : {
          key           = "${project_key}_${remediation.name}"
          has_role_file = lookup(remediation, "role_file", null) != null
        }
      ]
    ]) : item.key => item.has_role_file ? google_service_account.remediation_sa_project[item.key].email : null
  }

  # Compute for_each maps for project-level resources
  project_remediations_all = {
    for item in flatten([
      for project_key, project_value in var.projects : [
        for remediation_name, remediation in local.remediations_with_roles : {
          key         = "${project_key}_${remediation_name}"
          project_id  = project_value.project_id
          remediation = remediation
        }
      ]
    ]) : item.key => item
  }

  # Conditionally use project remediations based on org_level_permissions
  # Use filtered map to maintain type consistency (empty filter results in same type structure)
  project_custom_roles     = { for k, v in local.project_remediations_all : k => v if !var.org_level_permissions }
  project_service_accounts = { for k, v in local.project_remediations_all : k => v if !var.org_level_permissions }
  project_role_bindings    = { for k, v in local.project_remediations_all : k => v if !var.org_level_permissions }

  # Conditionally use org remediations based on org_level_permissions
  # Use filtered map to maintain type consistency
  org_custom_roles     = { for k, v in local.remediations_with_roles : k => v if var.org_level_permissions }
  org_service_accounts = { for k, v in local.remediations_with_roles : k => v if var.org_level_permissions }
  org_role_bindings    = { for k, v in local.remediations_with_roles : k => v if var.org_level_permissions }
}


# Create custom roles at organization level (if org_level_permissions is true)
resource "google_organization_iam_custom_role" "remediation_roles_org" {
  for_each = local.org_custom_roles

  org_id      = var.organization_id
  role_id     = "${replace(each.value.role_name, " ", "")}_${random_id.role_suffix.hex}"
  title       = each.value.role_name
  description = lookup(each.value, "description", "Stream Security GCP Remediation Role")
  permissions = jsondecode(file("${path.module}/templates/gcp_roles/${lookup(local.role_file_paths, each.value.role_file, each.value.role_file)}"))["includedPermissions"]
}

# Create custom roles at project level (if org_level_permissions is false)
resource "google_project_iam_custom_role" "remediation_roles_project" {
  for_each = local.project_custom_roles

  project     = each.value.project_id
  role_id     = "${replace(each.value.remediation.role_name, " ", "")}_${random_id.role_suffix.hex}"
  title       = each.value.remediation.role_name
  description = lookup(each.value.remediation, "description", "Stream Security GCP Remediation Role")
  permissions = jsondecode(file("${path.module}/templates/gcp_roles/${lookup(local.role_file_paths, each.value.remediation.role_file, each.value.remediation.role_file)}"))["includedPermissions"]
}

# Create service accounts at organization level (one per remediation)
resource "google_service_account" "remediation_sa_org" {
  for_each = local.org_service_accounts

  account_id   = lower(substr(replace(replace(each.value.name, "StreamSecurityGcp", "streamsec"), "/[^a-zA-Z0-9]/", "-"), 0, 30))
  display_name = "Service Account for ${each.value.name}"
  description  = "Service account for Stream Security remediation: ${each.value.name}"
  project      = local.sa_project
}

# Create service accounts at project level (one per project-remediation combination)
resource "google_service_account" "remediation_sa_project" {
  for_each = local.project_service_accounts

  account_id   = lower(substr(replace(replace(each.value.remediation.name, "StreamSecurityGcp", "streamsec"), "/[^a-zA-Z0-9]/", "-"), 0, 30))
  display_name = "Service Account for ${each.value.remediation.name}"
  description  = "Service account for Stream Security remediation: ${each.value.remediation.name}"
  project      = each.value.project_id
}

# Assign organization-level custom roles to org-level service accounts
resource "google_organization_iam_member" "sa_role_binding_org" {
  for_each = local.org_role_bindings

  org_id = var.organization_id
  role   = google_organization_iam_custom_role.remediation_roles_org[each.key].id
  member = "serviceAccount:${google_service_account.remediation_sa_org[each.key].email}"
}

# Assign project-level custom roles to project-level service accounts
resource "google_project_iam_member" "sa_role_binding_project" {
  for_each = local.project_role_bindings

  project = each.value.project_id
  role    = google_project_iam_custom_role.remediation_roles_project[each.key].id
  member  = "serviceAccount:${google_service_account.remediation_sa_project[each.key].email}"
}

# For every GCP remediation in every project, create a Google Workflow using the YAML in "runbooks/<remediation_name>.yaml"

resource "google_workflows_workflow" "gcp_remediations" {
  for_each = {
    for item in flatten([
      for project_key, project_value in var.projects : [
        for remediation in local.runbook_config.Remediations : {
          key         = "${project_key}_${remediation.name}"
          remediation = remediation
          project     = project_value.project_id
        }
      ]
      ]) : item.key => {
      remediation = item.remediation
      project     = item.project
    }
  }

  name                = each.value.remediation.name
  description         = lookup(each.value.remediation, "description", "Stream Security GCP Remediation Workflow")
  region              = data.google_client_config.current.region
  project             = each.value.project
  source_contents     = file("${path.module}/templates/runbooks/${each.value.remediation.name}.yaml")
  service_account     = local.workflow_sa_map[each.key]
  deletion_protection = false

  depends_on = [
    google_service_account.remediation_sa_org,
    google_service_account.remediation_sa_project,
    google_organization_iam_member.sa_role_binding_org,
    google_project_iam_member.sa_role_binding_project
  ]
}


resource "streamsec_gcp_response_ack" "this" {
  for_each         = { for k, v in var.projects : k => v }
  cloud_account_id = each.value.project_id
  runbook_list     = [for k, v in google_workflows_workflow.gcp_remediations : v.name]
  location         = data.google_client_config.current.region
  template_version = "1"

  depends_on = [google_workflows_workflow.gcp_remediations]
}
