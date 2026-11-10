output "function_name" {
  description = "Name of the collector function."
  value       = google_cloudfunctions2_function.collector.name
}

output "function_state" {
  description = "State of the collector function; ACTIVE once it is deployed."
  value       = google_cloudfunctions2_function.collector.state
}

output "trigger" {
  description = "Eventarc trigger that delivers the bucket's new files to the function."
  value       = google_cloudfunctions2_function.collector.event_trigger[0].trigger
}

output "service_account_email" {
  description = "Identity the function reads the bucket and receives events as."
  value       = google_service_account.collector.email
}

output "deployer_role" {
  description = "Custom role granted to deployment_service_account_email, or null when none was given."
  value       = one(google_project_iam_custom_role.deployer[*].id)
}

output "collection_url" {
  description = "Stream Security endpoint the files are sent to."
  value       = "${trimsuffix(var.stream_api_url, "/")}/api/v1/collection/${var.api_url_suffix}"
}
