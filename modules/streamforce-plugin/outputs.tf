output "function_url" {
  description = "The deployed plugin function URL (also acknowledged to Stream Security)."
  value       = google_cloudfunctions2_function.this.url
}

output "function_name" {
  description = "The deployed Cloud Function / Cloud Run service name."
  value       = google_cloudfunctions2_function.this.name
}

output "service_account_invoker" {
  description = "The service account granted run.invoker on the function."
  value       = var.invoker_sa_email
}
