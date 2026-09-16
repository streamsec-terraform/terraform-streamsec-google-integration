output "deployment_id" {
  description = "Infrastructure Manager deployment identifier used by the Lightlytics wizard."
  value       = local.deployment_id
}

output "integration_id" {
  description = "Stable integration identifier supplied by the Lightlytics wizard/backend."
  value       = var.integration_id
}

output "resource_suffix" {
  description = "Sanitized readable prefix and stable hash appended to module-owned resource names."
  value       = local.resource_suffix
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

output "build_repository_id" {
  description = "Dedicated Artifact Registry repository used for Cloud Function builds."
  value       = google_artifact_registry_repository.build.repository_id
}

output "source_bucket_name" {
  description = "Bucket containing the packaged Cloud Function source."
  value       = google_storage_bucket.source.name
}

output "integration_secret_id" {
  description = "Secret Manager secret containing the Stream integration token."
  value       = google_secret_manager_secret.integration_token.secret_id
}

output "deployer_role_id" {
  description = "Per-integration custom role granted to the deployment service account, or null when bootstrapping is disabled."
  value       = var.deployment_service_account_email == "" ? null : google_project_iam_custom_role.deployer[0].id
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
