variable "infra_manager_deployment_name" {
  description = "The deployment name of the Main Infra Manager."
  type        = string
}

variable "service_account_email" {
  description = "The service account email to use for the integration."
  type        = string
}

variable "google_project_id" {
  description = "The Google Project ID to use for the integration."
  type        = string
}

variable "google_region" {
  description = "The Google Region to use for the integration."
  type        = string
}

variable "org_id" {
  description = "The Organization ID to use for the log sink."
  type        = string
}

variable "function_source_bucket" {
  description = "The name of the bucket containing the Cloud Function source code."
  type        = string
  default     = "streamsec-production-public-artifacts"
}

variable "function_source_object" {
  description = "The name of the zip file (object) containing the Cloud Function source code."
  type        = string
  default     = "gcp-automated-integration.zip"
}

variable "pubsub_topic_name" {
  description = "The name of the PubSub topic for project create events."
  type        = string
  default     = "stream-security-automated-integration"
}

variable "log_sink_name" {
  description = "The name of the log sink for project create events."
  type        = string
  default     = "stream-security-automated-integration"
}

variable "function_name" {
  description = "The name of the Cloud Function handling project create events."
  type        = string
  default     = "stream-security-automated-integration"
}

variable "function_runtime" {
  description = "The runtime for the Cloud Function (e.g., python310, nodejs20, etc.)."
  type        = string
  default     = "python313"
}

variable "function_entry_point" {
  description = "The entry point for the Cloud Function."
  type        = string
  default     = "handle_project_event"
}

variable "function_timeout" {
  description = "Timeout (in seconds) for the Cloud Function."
  type        = number
  default     = 60
}

variable "ingress_settings" {
  description = "Ingress settings for the Cloud Function (e.g., ALLOW_INTERNAL_ONLY, ALLOW_ALL, etc.)."
  type        = string
  default     = "ALLOW_INTERNAL_ONLY"
}

variable "retry_policy" {
  description = "Retry policy for the Cloud Function event trigger (e.g., RETRY_POLICY_RETRY, RETRY_POLICY_DO_NOT_RETRY)."
  type        = string
  default     = "RETRY_POLICY_RETRY"
}
