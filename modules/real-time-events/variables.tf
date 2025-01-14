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
  default     = "nodejs22"
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
