output "role_name" {
  description = "The organization custom role granted to the hubs' scanners."
  value       = module.scanner_hub_access.role_name
}

output "scanner_service_account_emails" {
  description = "The hubs' scanner service accounts the role is granted to."
  value       = module.scanner_hub_access.scanner_service_account_emails
}

output "granted_on" {
  description = "Where the role is granted."
  value       = module.scanner_hub_access.granted_on
}
