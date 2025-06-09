output "pubsub_topic_name" {
  description = "The name of the PubSub topic for project create events."
  value       = google_pubsub_topic.project_events.name
}

output "log_sink_name" {
  description = "The name of the log sink for project create events."
  value       = google_logging_organization_sink.project_create.name
}

output "cloud_function_name" {
  description = "The name of the Cloud Function handling project create events."
  value       = google_cloudfunctions2_function.handle_project_create.name
}

output "cloud_function_service_account_email" {
  description = "The service account email used by the Cloud Function."
  value       = google_cloudfunctions2_function.handle_project_create.service_config[0].service_account_email
}

output "cloud_function_state" {
  description = "The state of the Cloud Function deployment."
  value       = google_cloudfunctions2_function.handle_project_create.state
}
