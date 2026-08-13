variable "project_id" {
  description = "GCP project ID where resources will be created"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Function and Scheduler"
  type        = string
  default     = "us-central1"
}

variable "api_url" {
  description = "REQUIRED. Full Stream Security collection URL the function posts to, e.g. https://app.streamsec.io (scheme included). Must be https:// — the request carries the API token and the full Vertex AI request/response bodies. http://localhost is permitted for local development only."
  type        = string

  # Plain http would transmit the X-Lightlytics-Token header and the logged prompt/response
  # payloads without transport encryption. localhost is exempt so the collector can be pointed
  # at a local stand-in during development.
  validation {
    condition     = can(regex("^https://", var.api_url)) || can(regex("^http://localhost(:[0-9]+)?(/|$)", var.api_url))
    error_message = "api_url must be a full https:// URL (http:// is only allowed for localhost during development)."
  }
}

variable "manage_apis" {
  description = "Whether this deployment manages (enables) the required project APIs. Set to false when the APIs are already enabled/owned elsewhere so this module doesn't redundantly own the shared google_project_service resources."
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

variable "secret_project" {
  description = "GCP project that owns the shared token secret, when it is not the project this pipeline deploys into. real-time-events creates the secret only in project_for_resources when org_level_sink = true, so a cross-project deployment must point here or the derived secret path resolves against the wrong project. Empty means the secret lives in project_id. Ignored when secret_version_name is set (the project is parsed from that path). With manage_secret_iam = true the deployer needs secretmanager.secrets.setIamPolicy in this project."
  type        = string
  default     = ""
}

variable "manage_secret_iam" {
  description = "Whether this module grants the collector SA secretAccessor on the secret. Set false when the secret is owned elsewhere and the deployer lacks secretmanager.secrets.setIamPolicy — the secret owner must then grant the collector SA (output service_account_email) roles/secretmanager.secretAccessor out-of-band."
  type        = bool
  default     = true
}

variable "secret_version_name" {
  description = "Optional override of the full Secret Manager secret VERSION resource name read by the function (e.g. projects/<p>/secrets/<s>/versions/latest, or .../locations/<r>/... for regional). When empty it is derived from project_id + secret_name + regional_secret. Set this for standalone use against an arbitrary secret."
  type        = string
  default     = ""
}

variable "bigquery_grant_scope" {
  description = "Where the module grants BigQuery access for the collector (read) and the Vertex AI service agent (write). 'dataset' (default, least privilege) scopes both to the logging dataset — but BigQuery dataset ACLs ARE the dataset resource, so this requires bigquery.datasets.update on it (roles/bigquery.dataOwner or admin); a deployer with only datasets.create can create the dataset but not later modify its access, and the apply fails with 403. 'project' falls back to project-level bigquery.dataViewer/dataEditor bindings, which is broader but needs only project setIamPolicy. 'none' grants nothing and leaves both to be granted out-of-band. bigquery.jobUser is always project-level regardless — it has no dataset-scoped equivalent."
  type        = string
  default     = "dataset"

  validation {
    condition     = contains(["dataset", "project", "none"], var.bigquery_grant_scope)
    error_message = "bigquery_grant_scope must be one of: dataset, project, none."
  }
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
  description = "BigQuery table the publisher model logs to (also used as the prefix for the collector's wildcard read, '<table>*'). Must be a valid BigQuery table name — no trailing underscore, which Vertex rejects when parsing the bq:// destination URI."
  type        = string
  default     = "request_response_logging"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.bigquery_table)) && !endswith(var.bigquery_table, "_")
    error_message = "bigquery_table must be alphanumeric/underscore and must not end with '_' (Vertex rejects a trailing underscore in the bq:// destination URI)."
  }
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
  description = "Number of concurrent HTTP requests when sending logs to Stream Security. Must be >= 1."
  type        = number
  default     = 20

  # Passed straight to ThreadPoolExecutor(max_workers=...), which raises ValueError on any
  # non-positive value — every non-empty poll would fail at runtime.
  validation {
    condition     = var.batch_size >= 1 && floor(var.batch_size) == var.batch_size
    error_message = "batch_size must be a positive integer (>= 1)."
  }
}

variable "name_prefix" {
  description = "Prefix for all resource names (for multi-deployment isolation)"
  type        = string
  default     = "streamsec"

  # The service account account_id is built as "<name_prefix>-vtx-col" and GCP caps
  # account_id at 30 chars. Length is also enforced by a precondition on
  # google_service_account.collector.
  validation {
    condition     = length("${var.name_prefix}-vtx-col") <= 30
    error_message = "name_prefix is too long: '<name_prefix>-vtx-col' must be <= 30 chars (GCP service account account_id limit)."
  }
}

variable "enable_request_response_logging" {
  description = "Whether to manage Vertex AI request-response logging on the publisher models. When true the caller MUST pass a configured `restapi` provider (see README); when false no restapi resources are created and the provider need not be configured. Note this config is singular per model+location for the whole project: enabling it here overwrites any BigQuery destination another deployment set on the same model+region."
  type        = bool
  default     = true
}

variable "vertex_ai_models" {
  description = "Publisher model names to enable request-response logging on (e.g., [\"gemini-2.5-flash\", \"gemini-2.5-pro\"]). Logging is enabled per model; all models share the same env-prefixed BigQuery dataset/table (rows are distinguished by the model column)."
  type        = list(string)
  default     = ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"]

  validation {
    condition     = alltrue([for m in var.vertex_ai_models : length(trimspace(m)) > 0])
    error_message = "vertex_ai_models must not contain empty strings."
  }
}

variable "logging_sampling_rate" {
  description = "Fraction of requests to log (0.0 to 1.0)"
  type        = number
  default     = 1.0

  # The API defines samplingRate as a fraction in range(0,1] -- 0 is rejected rather than treated
  # as "log nothing". Use enable_request_response_logging = false to turn logging off.
  validation {
    condition     = var.logging_sampling_rate > 0 && var.logging_sampling_rate <= 1
    error_message = "logging_sampling_rate must be greater than 0.0 and at most 1.0. To disable logging entirely, set enable_request_response_logging = false."
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
