variable "project_id" {
  description = "Project to deploy the collector into. It must hold bucket_name: Eventarc delivers Cloud Storage events only to triggers in the bucket's project."
  type        = string
}

variable "region" {
  description = "Region of the collector function and its build resources. The trigger itself is created in the bucket's location."
  type        = string
  default     = "us-central1"
}

variable "bucket_name" {
  description = "Cloud Storage bucket the files are written to, e.g. the bucket GitHub Enterprise streams its audit log into."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a Cloud Storage bucket name, without gs://."
  }
}

variable "api_url_suffix" {
  description = "Stream Security collection endpoint each file is sent to, as <stream_api_url>/api/v1/collection/<api_url_suffix>. github-audit for GitHub Enterprise audit logs."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+([/-][a-z0-9]+)*$", var.api_url_suffix))
    error_message = "api_url_suffix must be a collection endpoint such as github-audit."
  }
}

variable "stream_api_url" {
  description = "The URL you open Stream Security at, e.g. https://app.streamsec.io."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/?$", var.stream_api_url))
    error_message = "stream_api_url must be an https:// URL with no path."
  }
}

variable "stream_collection_token" {
  description = "Collection token of the Stream Security integration, shown in its integration panel."
  type        = string
  sensitive   = true
}

variable "function_timeout_seconds" {
  description = "Timeout of one file's delivery, in seconds."
  type        = number
  default     = 120
}

variable "max_instance_count" {
  description = "Maximum number of function instances delivering files at once."
  type        = number
  default     = 10
}

variable "manage_apis" {
  description = "Enable the APIs the collector needs. Set to false when they are managed elsewhere."
  type        = bool
  default     = true
}

variable "deployment_service_account_email" {
  description = "Service account Terraform runs as, when it lacks resource-level setIamPolicy (the Infrastructure Manager runner). It is granted a custom role with only those permissions. Leave empty when Terraform runs with Owner."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels added to the collector's resources."
  type        = map(string)
  default     = {}
}
