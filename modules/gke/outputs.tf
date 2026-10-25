output "function_names" {
  description = "Function name per deployment project."
  value       = { for k, f in google_cloudfunctions2_function.this : k => f.name }
}

output "topic_ids" {
  description = "Pub/Sub topic ID per deployment project."
  value       = { for k, t in google_pubsub_topic.this : k => t.id }
}

output "service_account_emails" {
  description = "Function service account email per deployment project."
  value       = { for k, sa in google_service_account.this : k => sa.email }
}

output "sink_writer_identities" {
  description = "Log sink writer identity per deployment project."
  value       = local.sink_writer_identities
}

output "secret_ids" {
  description = "Token secret ID per deployment project."
  value       = { for k, s in google_secret_manager_secret.this : k => s.id }
}
