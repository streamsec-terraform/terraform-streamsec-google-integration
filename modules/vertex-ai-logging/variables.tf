variable "project_id" {
  description = "GCP project ID where resources will be created"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Function and Scheduler"
  type        = string
  default     = "us-central1"
}

variable "secret_name" {
  description = "Secret Manager secret ID holding the Stream Security API token (reuses the secret created by the real-time-events module)."
  type        = string
  default     = "stream-security-collection-token"
}

variable "create_bigquery_dataset" {
  description = "Whether to create the BigQuery dataset and logging table. Set to false if the dataset already exists (e.g., customer configured logging manually)"
  type        = bool
  default     = true
}

variable "bigquery_dataset" {
  description = "BigQuery dataset ID for Vertex AI request-response logs (created if create_bigquery_dataset=true, referenced otherwise)"
  type        = string
  default     = "vertex_ai_logs"
}

variable "bigquery_table" {
  description = "BigQuery table name (supports wildcard suffix for date-sharded tables, e.g., 'predictions_')"
  type        = string
  default     = "predictions_"
}

variable "bigquery_location" {
  description = "BigQuery dataset location (must match the region where Vertex AI endpoints run)"
  type        = string
  default     = "US"
}

variable "bigquery_log_retention_days" {
  description = "Number of days to retain request-response logs in BigQuery (default partition expiration)"
  type        = number
  default     = 30
}

variable "schedule_cron" {
  description = "Cloud Scheduler cron expression for polling interval"
  type        = string
  default     = "*/5 * * * *"
}

variable "function_memory_mb" {
  description = "Memory allocation for the Cloud Function in MB"
  type        = number
  default     = 512
}

variable "function_timeout_seconds" {
  description = "Timeout for the Cloud Function in seconds"
  type        = number
  default     = 300
}

variable "batch_size" {
  description = "Number of concurrent HTTP requests when sending logs to Stream Security"
  type        = number
  default     = 20
}

variable "name_prefix" {
  description = "Prefix for all resource names (for multi-deployment isolation)"
  type        = string
  default     = "streamsec"
}

variable "enable_request_response_logging" {
  description = "Whether to enable Vertex AI request-response logging on the publisher model via local-exec. Requires Python with the google-cloud-aiplatform SDK installed."
  type        = bool
  default     = true
}

variable "vertex_ai_model" {
  description = "Publisher model name to enable request-response logging on (e.g., gemini-2.5-flash, gemini-2.5-pro)"
  type        = string
  default     = "gemini-2.5-flash"
}

variable "logging_sampling_rate" {
  description = "Fraction of requests to log (0.0 to 1.0)"
  type        = number
  default     = 1.0

  validation {
    condition     = var.logging_sampling_rate >= 0 && var.logging_sampling_rate <= 1
    error_message = "logging_sampling_rate must be between 0.0 and 1.0."
  }
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default = {
    managed-by = "terraform"
    component  = "streamsec-vertex-ai-collection"
  }
}
