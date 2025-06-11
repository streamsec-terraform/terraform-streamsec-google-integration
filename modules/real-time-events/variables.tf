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
  default     = "python313"
}

variable "ingress_settings" {
  description = "The ingress settings of the Cloud Function to create."
  type        = string
  default     = "ALLOW_INTERNAL_ONLY"
}

variable "function_entry_point" {
  description = "The entry point of the Cloud Function to create."
  type        = string
  default     = "handle_project_event"
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
  description = "Whether to use Secret Manager for the API token instead of direct value."
  type        = bool
  default     = false
}

variable "secret_name" {
  description = "The name of the secret in Secret Manager containing the API token."
  type        = string
  default     = "stream-security-collection-token"
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
