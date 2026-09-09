output "deployment_id" {
  description = "Infrastructure Manager deployment identifier used by the Lightlytics wizard."
  value       = local.deployment_id
}

output "project_id" {
  description = "GCP project hosting the deployment."
  value       = var.project_id
}

output "region" {
  description = "GCP region hosting the deployment."
  value       = var.region
}

output "stream_template_version" {
  description = "Release ref supplied by the deployment command."
  value       = var.stream_template_version
}

output "function_name" {
  description = "Name of the deployed Cloud Function."
  value       = google_cloudfunctions2_function.collector.name
}

output "function_uri" {
  description = "IAM-protected URI invoked by Cloud Scheduler."
  value       = google_cloudfunctions2_function.collector.url
}

output "service_account_email" {
  description = "Runtime and Scheduler OIDC service account."
  value       = google_service_account.collector.email
}

output "build_service_account_email" {
  description = "Dedicated service account used to build the Cloud Function image."
  value       = google_service_account.build.email
}

output "scheduler_name" {
  description = "Name of the Cloud Scheduler polling job."
  value       = google_cloud_scheduler_job.poll.name
}

output "scheduler_schedule" {
  description = "Effective Cloud Scheduler cron expression."
  value       = google_cloud_scheduler_job.poll.schedule
}

output "vpc_connector_id" {
  description = "Serverless VPC Access connector used for private firewall management traffic."
  value       = google_vpc_access_connector.collector.id
}
