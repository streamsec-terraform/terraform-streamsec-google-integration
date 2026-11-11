variable "project_id" {
  description = "GCP project that holds the bucket, and in which to deploy the collector."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,28}[a-z0-9])$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  description = "GCP region for the collector function."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region such as us-central1."
  }
}

variable "bucket_name" {
  description = "Cloud Storage bucket the files are written to, e.g. the bucket GitHub Enterprise streams its audit log into."
  type        = string
}

variable "api_url_suffix" {
  description = "Stream Security collection endpoint the files are sent to, e.g. github-audit."
  type        = string
}

variable "collector_id" {
  description = "Gives this collector names of its own on a bucket other collectors also use, e.g. the Stream Security workspace's ID. Empty: one collector per bucket."
  type        = string
  default     = ""
}

variable "stream_api_url" {
  description = "Stream Security tenant base URL."
  type        = string
}

variable "stream_collection_token" {
  description = "Collection token of the Stream Security integration."
  type        = string
  sensitive   = true
}
