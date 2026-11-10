output "function_name" {
  description = "Name of the collector function."
  value       = module.gcs_file_collector.function_name
}

output "function_state" {
  description = "State of the collector function; ACTIVE once it is deployed."
  value       = module.gcs_file_collector.function_state
}

output "service_account_email" {
  description = "Identity the function reads the bucket and receives events as."
  value       = module.gcs_file_collector.service_account_email
}

output "collection_url" {
  description = "Stream Security endpoint the files are sent to."
  value       = module.gcs_file_collector.collection_url
}
