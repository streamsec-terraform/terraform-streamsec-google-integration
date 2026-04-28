provider "google" {
  project = var.project
  region  = var.region
}

# Reads STREAMSEC_HOST, STREAMSEC_API_TOKEN, and STREAMSEC_WORKSPACE_ID from env
provider "streamsec" {}

variable "project" {
  description = "GCP project ID to deploy response resources into."
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Workflows deployment."
  type        = string
}

module "response" {
  source = "../../modules/response"

  projects              = [var.project]
  org_level_permissions = false
  auto_grant_workflow_invoker = false
}
