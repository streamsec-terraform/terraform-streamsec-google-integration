output "collection_url" {
  description = "Stream Security collection base URL the function posts to"
  value       = var.api_url
}

output "function_name" {
  description = "Name of the deployed Cloud Function"
  value       = google_cloudfunctions2_function.vertex_ai_collector.name
}

output "function_url" {
  description = "URL of the deployed Cloud Function (for manual trigger)"
  value       = google_cloudfunctions2_function.vertex_ai_collector.url
}

output "service_account_email" {
  description = "Service account email used by the Cloud Function"
  value       = google_service_account.collector.email
}

output "scheduler_job_name" {
  description = "Name of the Cloud Scheduler job"
  value       = google_cloud_scheduler_job.poll_trigger.name
}

output "watermark_bucket" {
  description = "GCS bucket used for watermark state"
  value       = google_storage_bucket.state.name
}

output "bigquery_dataset_id" {
  description = "Effective (prefixed) BigQuery dataset ID for Vertex AI logs, <name_prefix>_<bigquery_dataset>."
  value       = local.bigquery_dataset_id
}

output "bigquery_table_prefix" {
  description = "BigQuery table prefix for Vertex AI logging (date-sharded tables created by Vertex AI)"
  value       = var.bigquery_table
}
