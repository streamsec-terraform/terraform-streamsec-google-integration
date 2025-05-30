################################################################################
# FlowLogs Variables
################################################################################

variable "projects" {
  description = "A list of projects to create Service Accounts for."
  type        = any
}


################################################################################
# FlowLogs Cloud Function Variables
################################################################################

variable "function_name" {
  description = "The name of the Cloud Function to create."
  type        = string
  default     = "stream-security-flowlogs-function"
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
  default     = "StorageFlowlogsCollection"
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
  default     = "gcp-flow-logs-collection.zip"
}

################################################################################
# FlowLogs General Variables
################################################################################

variable "labels" {
  description = "The labels to apply to the Stream Security GCP Project resources."
  type        = map(string)
  default     = {}
}
