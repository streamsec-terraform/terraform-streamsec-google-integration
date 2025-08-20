################################################################################
# Real Time Events Variables
################################################################################

variable "projects" {
  description = "A list of projects to create Service Accounts for."
  type        = any
}

################################################################################
# Real Time Events Pub/Sub Variables
################################################################################

variable "pubsub_topic_name" {
  description = "The name of the Pub/Sub topic to create."
  type        = string
  default     = "stream-security-events-topic"
}

variable "topic_message_retention_duration" {
  description = "The duration to retain messages in the Pub/Sub topic."
  type        = string
  default     = "259200s"
}

################################################################################
# Real Time Events Log Sink Variables
################################################################################

variable "log_sink_name" {
  description = "The name of the log sink to create."
  type        = string
  default     = "stream-security-events-sink"
}

variable "log_sink_filter" {
  description = "The filter to apply to the log sink. (use only if you have more than 100 projects)"
  type        = string
  default     = ""
}

################################################################################
# Real Time Events Cloud Function Variables
################################################################################

variable "function_name" {
  description = "The name of the Cloud Function to create."
  type        = string
  default     = "stream-security-events-function"
}

variable "function_runtime" {
  description = "The runtime of the Cloud Function to create."
  type        = string
  default     = "nodejs22"
}

variable "function_service_account_id" {
  description = "The ID of the service account to create for the Cloud Function."
  type        = string
  default     = "stream-security-function-sa"
}

variable "function_service_account_display_name" {
  description = "The display name of the service account to create for the Cloud Function."
  type        = string
  default     = "Stream Security Events Function Service Account"
}

variable "function_service_account_description" {
  description = "The description of the service account to create for the Cloud Function."
  type        = string
  default     = "Service account for Stream Security events collection Cloud Function"
}

variable "ingress_settings" {
  description = "The ingress settings of the Cloud Function to create."
  type        = string
  default     = "ALLOW_INTERNAL_ONLY"
}

variable "function_entry_point" {
  description = "The entry point of the Cloud Function to create."
  type        = string
  default     = "streamsec-audit-logs-collector"
}

variable "function_timeout" {
  description = "The timeout of the Cloud Function to create."
  type        = number
  default     = 5
}

variable "source_bucket_name" {
  description = "The name of the bucket containing the Cloud Function source code."
  type        = string
  default     = "streamsec-production-public-artifacts"
}

variable "source_archive_name" {
  description = "The name of the archive containing the Cloud Function source code."
  type        = string
  default     = "gcp-events-collection.zip"
}

################################################################################
# Real Time Events General Variables
################################################################################

variable "labels" {
  description = "The labels to apply to the Stream Security GCP Project resources."
  type        = map(string)
  default     = {}
}

variable "use_secret_manager" {
  description = "Boolean to determine if the Secret Manager should be used to store the API token."
  type        = bool
  default     = true
}

variable "secret_name" {
  description = "The name of the secret in Secret Manager containing the API token."
  type        = string
  default     = "stream-security-collection-token"
}

variable "regional_secret" {
  description = "If true, create a regional secret in Secret Manager containing the API token. If false, create a global secret in Secret Manager containing the API token."
  type        = bool
  default     = true
}

variable "org_level_sink" {
  description = "If true, create a single org-level log sink, topic, and function. Otherwise, create per-project."
  type        = bool
  default     = true
}

variable "organization_id" {
  description = "The organization ID to use for org-level log sink. Required if org_level_sink is true."
  type        = string
  default     = ""
}

variable "project_for_resources" {
  description = "The project ID to use for resources. Required if org_level_sink is true."
  type        = string
  default     = ""
}
