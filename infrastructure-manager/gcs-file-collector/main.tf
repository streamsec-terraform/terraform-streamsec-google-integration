provider "google" {
  project = var.project_id
  region  = var.region
}

module "gcs_file_collector" {
  source = "../../modules/gcs-file-collector"

  project_id              = var.project_id
  region                  = var.region
  bucket_name             = var.bucket_name
  api_url_suffix          = var.api_url_suffix
  stream_api_url          = var.stream_api_url
  stream_collection_token = var.stream_collection_token

  # The console's setup always executes Terraform as this Infra Manager runner.
  deployment_service_account_email = "infra-manager@${var.project_id}.iam.gserviceaccount.com"
  # The console's setup grants it once, so deleting one deployment cannot take it from the rest.
  grant_storage_agent_publisher = false
}
