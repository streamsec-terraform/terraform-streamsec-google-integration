output "role_name" {
  description = "The organization custom role granted to the hub's scanner."
  value       = module.scanner_hub_access.role_name
}

output "scanner_service_account_email" {
  description = "The hub scanner's service account the role is granted to."
  value       = module.scanner_hub_access.scanner_service_account_email
}

output "granted_on" {
  description = "Where the role is granted."
  value       = module.scanner_hub_access.granted_on
}
