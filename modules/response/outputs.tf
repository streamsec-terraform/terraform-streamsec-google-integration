output "workflows" {
  description = "Map of created workflow resources"
  value       = google_workflows_workflow.gcp_remediations
}

output "service_accounts_org" {
  description = "Map of organization-level service accounts created for remediations"
  value       = var.org_level_permissions ? google_service_account.remediation_sa_org : {}
}

output "service_accounts_project" {
  description = "Map of project-level service accounts created for remediations"
  value       = !var.org_level_permissions ? google_service_account.remediation_sa_project : {}
}

output "custom_roles_org" {
  description = "Map of organization-level custom roles created for remediations"
  value       = var.org_level_permissions ? google_organization_iam_custom_role.remediation_roles_org : {}
}

output "custom_roles_project" {
  description = "Map of project-level custom roles created for remediations"
  value       = !var.org_level_permissions ? google_project_iam_custom_role.remediation_roles_project : {}
}

output "role_suffix" {
  description = "Random suffix appended to custom role IDs to avoid conflicts with pending deletions"
  value       = random_id.role_suffix.hex
}
