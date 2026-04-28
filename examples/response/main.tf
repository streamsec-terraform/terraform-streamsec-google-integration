terraform {
  required_version = ">= 1.5"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.13"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.10"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

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

  projects                    = [var.project]
  region                      = var.region
  org_level_permissions       = false
  auto_grant_workflow_invoker = false
}
