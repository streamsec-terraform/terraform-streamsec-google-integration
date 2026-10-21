output "role_id" {
  description = "ID of the organization custom role granted to the hub's scanner: streamsecVolumeScannerTarget."
  value       = google_organization_iam_custom_role.target.role_id
}

output "role_name" {
  description = "Full name of the custom role, organizations/<org_id>/roles/streamsecVolumeScannerTarget, as IAM bindings name it."
  value       = google_organization_iam_custom_role.target.name
}

output "scanner_service_account_email" {
  description = "The hub scanner's service account the role is granted to."
  value       = local.scanner_sa_email
}

output "granted_on" {
  description = "Where the role is granted: scope is organization, folders or projects, and ids the organization ID, folder IDs or project IDs."
  value = {
    scope = local.scope
    ids = concat(
      [for b in google_organization_iam_member.target : b.org_id],
      keys(google_folder_iam_member.target),
      keys(google_project_iam_member.target),
    )
  }
}
