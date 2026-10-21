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

output "sink_names" {
  description = "Log sink name per deployment project."
  value = var.org_level_sink ? {
    for k in keys(local.deploy_projects) : k => google_logging_organization_sink.this[0].name
    } : {
    for k, s in google_logging_project_sink.this : k => s.name
  }
}

output "secret_ids" {
  description = "Token secret ID per deployment project."
  value       = { for k, s in google_secret_manager_secret.this : k => s.id }
}
