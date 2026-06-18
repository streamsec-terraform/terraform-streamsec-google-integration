variable "project_id" {
  description = "GCP project ID where resources will be created"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Function and Scheduler"
  type        = string
  default     = "us-central1"
}

variable "env" {
  description = "REQUIRED. Stream Security environment / subdomain prefix (e.g. 'app', 'demo'). Used to derive the collection URL (https://<env>.<streamsec_domain>) and to suffix resource names so the module can be deployed once per environment (separate state/workspace) against the same project."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.env))
    error_message = "env is required and must be lowercase alphanumeric/hyphen (it is used in DNS-style hostnames and GCP resource names)."
  }
}

variable "api_url" {
  description = "Optional explicit Stream Security collection URL, e.g. https://app.streamsec.io. Overrides the env-derived URL (https://<env>.<streamsec_domain>). Leave empty to derive from env + streamsec_domain."
  type        = string
  default     = ""
}

variable "streamsec_domain" {
  description = "Base domain used to build the collection URL from var.env (https://<env>.<streamsec_domain>). Set this to target non-prod environments, e.g. 'staging.streamsec.io' or 'dev.streamsec.io'."
  type        = string
  default     = "streamsec.io"
}

variable "manage_apis" {
  description = "Whether this deployment manages (enables) the required project APIs. Set to false for additional per-env deployments in the SAME project so they don't redundantly own the shared google_project_service resources."
  type        = bool
  default     = true
}

variable "use_secret_manager" {
  description = "Whether the Stream Security API token is stored in Secret Manager. This module reads the token from Secret Manager and therefore requires it to be true (matches the real-time-events module input that owns the shared secret)."
  type        = bool
  default     = true

  validation {
    condition     = var.use_secret_manager
    error_message = "vertex-ai-logging reads the token from Secret Manager and requires use_secret_manager = true."
  }
}

variable "secret_name" {
  description = "Secret Manager secret ID holding the Stream Security API token. Must match the secret created by the real-time-events module (same project) so the collector reads the shared secret."
  type        = string
  default     = "stream-security-collection-token"
}

variable "regional_secret" {
  description = "Whether the shared token secret is a regional secret (true) or global (false). Must match the real-time-events regional_secret input so the collector resolves the correct secret resource path."
  type        = bool
  default     = true
}

variable "secret_version_name" {
  description = "Optional override of the full Secret Manager secret VERSION resource name read by the function (e.g. projects/<p>/secrets/<s>/versions/latest, or .../locations/<r>/... for regional). When empty it is derived from project_id + secret_name + regional_secret. Set this for standalone use against an arbitrary secret."
  type        = string
  default     = ""
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

  # The service account account_id is built as "<name_prefix>-vtx-col-<env>" and GCP caps
  # account_id at 30 chars. This is a conservative prefix-only sanity check; the full
  # env-inclusive length is enforced by a precondition on google_service_account.collector.
  validation {
    condition     = length("${var.name_prefix}-vtx-col") <= 26
    error_message = "name_prefix is too long: '<name_prefix>-vtx-col' must be <= 26 chars to leave room for '-<env>' (GCP service account account_id limit is 30)."
  }
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
