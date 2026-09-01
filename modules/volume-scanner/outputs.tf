output "service_account_email" {
  description = "Service account the orchestrator and its Batch workers run as."
  value       = google_service_account.scanner.email
}

output "custom_role_id" {
  description = "Least-privilege custom role granted to the scanner service account."
  value       = google_project_iam_custom_role.scanner.id
}

output "orchestrator_job_name" {
  description = "Cloud Run Job that fans out the scan."
  value       = google_cloud_run_v2_job.orchestrator.name
}

output "network" {
  description = "Isolated VPC the no-external-IP scan workers run in."
  value       = google_compute_network.scanner.id
}

output "subnetwork" {
  description = "Subnet the scan workers attach to."
  value       = google_compute_subnetwork.scanner.id
}
