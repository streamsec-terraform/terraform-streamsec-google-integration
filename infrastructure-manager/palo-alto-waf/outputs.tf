output "deployment_id" {
  description = "Infrastructure Manager deployment identifier used by the Lightlytics wizard."
  value       = module.palo_alto_waf.deployment_id
}

output "project_id" {
  description = "GCP project hosting the deployment."
  value       = module.palo_alto_waf.project_id
}

output "region" {
  description = "GCP region hosting the deployment."
  value       = module.palo_alto_waf.region
}

output "stream_template_version" {
  description = "Release ref supplied by the deployment command."
  value       = module.palo_alto_waf.stream_template_version
}

output "function_name" {
  description = "Name of the deployed Cloud Function."
  value       = module.palo_alto_waf.function_name
}

output "function_uri" {
  description = "IAM-protected URI invoked by Cloud Scheduler."
  value       = module.palo_alto_waf.function_uri
}

output "service_account_email" {
  description = "Runtime and Scheduler OIDC service account."
  value       = module.palo_alto_waf.service_account_email
}

output "scheduler_name" {
  description = "Name of the Cloud Scheduler polling job."
  value       = module.palo_alto_waf.scheduler_name
}

output "scheduler_schedule" {
  description = "Effective Cloud Scheduler cron expression."
  value       = module.palo_alto_waf.scheduler_schedule
}

output "vpc_connector_id" {
  description = "Serverless VPC Access connector used for private firewall management traffic."
  value       = module.palo_alto_waf.vpc_connector_id
}
