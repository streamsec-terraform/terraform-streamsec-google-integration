output "role_id" {
  description = "ID of the organization custom role granted to the hubs' scanners: streamsecVolumeScannerTarget."
  value       = local.role_id
}

output "role_name" {
  description = "Full name of the custom role, organizations/<org_id>/roles/streamsecVolumeScannerTarget, as IAM bindings name it."
  value       = local.role_name
}

output "scanner_service_account_emails" {
  description = "The scanner service accounts the role is granted to: those of hub_project_ids, and scanner_service_account_emails. Empty when an instance that creates the role lists no scanner."
  value       = sort(local.scanner_sa_emails)

  # Allowed empty while the instance owns the role: removing the last hub must
  # revoke its binding and keep the role, which other hubs may still use.
  precondition {
    condition     = var.create_role || length(local.scanner_sa_emails) > 0
    error_message = "With create_role = false, name at least one scanner to grant the role to, in hub_project_ids or scanner_service_account_emails; otherwise the module does nothing."
  }
}

output "granted_on" {
  description = "Where the role is granted: scope is organization, folders or projects, and ids the organization ID, folder IDs or project IDs."
  value = {
    scope = local.scope
    ids = sort(distinct(concat(
      [for b in google_organization_iam_member.target : b.org_id],
      [for b in local.folder_bindings : b.folder_id],
      [for b in local.project_bindings : b.project_id],
    )))
  }
}
