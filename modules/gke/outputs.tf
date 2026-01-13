output "logs_bucket" {
  value = google_storage_bucket.logs.name
}

output "org_sink_writer_identity" {
  value = google_logging_organization_sink.org_sink.writer_identity
}

output "gcs_service_agent_email" {
  value = local.gcs_service_agent_email
}

output "function_name" {
  value = google_cloudfunctions_function.collector.name
}

output "secret_resource_path" {
  value = local.secret_resource_path
}
