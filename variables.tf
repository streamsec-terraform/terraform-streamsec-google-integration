################################################################################
# Stream Security GCP Project Variables
################################################################################
variable "exclude_projects" {
  description = "A list of projects to exclude from the Organization Integration."
  type        = list(string)
  default     = []
}

variable "excluded_project_prefixes" {
  description = "A list of project display name prefixes to exclude. Any project whose display name starts with one of these prefixes will be excluded."
  type        = list(string)
  default     = []
}

variable "excluded_project_strings" {
  description = "A list of substrings to exclude. Any project whose display name contains one of these strings will be excluded."
  type        = list(string)
  default     = []
}

variable "excluded_project_id_prefixes" {
  description = "A list of project ID prefixes to exclude. Any project whose project ID starts with one of these prefixes will be excluded."
  type        = list(string)
  default     = []
}

variable "excluded_project_id_strings" {
  description = "A list of substrings to exclude by project ID. Any project whose project ID contains one of these strings will be excluded."
  type        = list(string)
  default     = []
}

variable "include_projects" {
  description = "A list of projects to include from the Organization Integration. If not set, all projects will be included."
  type        = list(string)
  default     = []
}

variable "org_id" {
  description = "The Organization ID to create the Service Account in (REQUIRED if create_sa is true)."
  type        = string
  default     = null
}

variable "project_for_sa" {
  description = "The project to create the Service Account in (if not set and create_sa is true, will take provider project id)."
  type        = string
  default     = null
}

################################################################################
# Stream Security Application Registration Variables
################################################################################

variable "create_sa" {
  description = "Boolean to determine if the Service Account should be created. If false, the existing service account must have organization level permissions."
  type        = bool
  default     = true
}

variable "existing_sa_json_file_path" {
  description = "The path to the JSON file for the existing Service Account."
  type        = string
  default     = null
}

variable "sa_account_id" {
  description = "The account ID for the Service Account to be created for Stream Security."
  type        = string
  default     = "stream-security"
}

variable "sa_display_name" {
  description = "The display name for the Service Account to be created for Stream Security."
  type        = string
  default     = "Stream Security"
}

variable "sa_description" {
  description = "The description for the Service Account to be created for Stream Security."
  type        = string
  default     = "Stream Security Service Account"
}

################################################################################
# Function Service Account Variables
################################################################################
variable "use_existing_function_sa" {
  description = "Boolean to determine if the existing Function Service Account should be used."
  type        = bool
  default     = false
}

variable "function_service_account_id" {
  description = "The account ID of the Service Account to be used for Stream Security Functions."
  type        = string
  default     = null
}

variable "grant_function_service_account_roles" {
  description = "Boolean to determine if the Function Service Account should be granted the necessary roles."
  type        = bool
  default     = false
}

################################################################################
# Real Time Events Module
################################################################################

variable "enable_real_time_events" {
  description = "Boolean to determine if Real Time Events should be enabled."
  type        = bool
  default     = true
}

variable "use_secret_manager" {
  description = "Boolean to determine if the Secret Manager should be used to store the API token."
  type        = bool
  default     = true
}

variable "secret_name" {
  description = "The name of the Secret Manager secret to store the API token."
  type        = string
  default     = "stream-security-collection-token"
}

variable "org_level_sink" {
  description = "If true, create a single org-level log sink, topic, and function. Otherwise, create per-project."
  type        = bool
  default     = true
}

variable "project_for_resources" {
  description = "The project ID to use for resources. Required if org_level_sink is true."
  type        = string
  default     = ""
}

variable "log_sink_filter" {
  description = "The filter to apply to the log sink. (use only if you have more than 100 projects)"
  type        = string
  default     = ""
}

variable "regional_secret" {
  description = "If true, create a regional secret in Secret Manager containing the API token. If false, create a global secret in Secret Manager containing the API token."
  type        = bool
  default     = true
}


################################################################################
# Response Module
################################################################################

variable "response_enabled_projects" {
  description = "A list of project IDs to create response resources for."
  type        = list(string)
  default     = []
}

variable "region" {
  description = "GCP region for Cloud Workflows deployment. Required when response_enabled_projects is set."
  type        = string
  default     = null
}

variable "response_org_level_permissions" {
  description = "If true, create response service accounts and custom roles at organization level. If false, create them at project level."
  type        = bool
  default     = true
}
variable "exclude_runbooks" {
  description = "List of response runbook names to exclude from deployment. Useful for disabling specific remediations."
  type        = list(string)
  default     = []
}

variable "auto_grant_workflow_invoker" {
  description = "If true, automatically grant roles/workflows.invoker permission to the specified service account."
  type        = bool
  default     = true
}

################################################################################
# GKE Module
################################################################################

variable "enable_gke_logs" {
  description = "Boolean to determine if GKE Logs collection should be enabled."
  type        = bool
  default     = false
}

variable "gke_bucket_name" {
  description = "Base bucket name for GKE audit logs storage (must be globally unique)."
  type        = string
  default     = "gke-audit-logs"
}

variable "gke_bucket_location" {
  description = "Bucket location/region or multi-region for GKE logs (e.g., US, EU, ASIA, us-central1)."
  type        = string
  default     = "US"
}

variable "gke_api_url" {
  description = "Stream Security API URL for GKE logs collection, e.g. https://app.streamsec.io"
  type        = string
  default     = "https://app.streamsec.io"
}

variable "gke_secret_name" {
  description = "Secret Manager secret name holding the StreamSec GKE collection token."
  type        = string
  default     = "streamsec-gke-logs-token"
}

variable "gke_streamsec_token" {
  description = "StreamSec collection token for GKE logs (stored in Secret Manager)."
  type        = string
  sensitive   = true
  default     = ""
}

################################################################################
# Vertex AI Logging Module
################################################################################

variable "enable_vertex_ai_logging" {
  description = "Boolean to determine if Vertex AI request-response logging should be enabled."
  type        = bool
  default     = false
}

variable "vertex_ai_api_url" {
  description = "Full Stream Security collection URL for Vertex AI logging (scheme included; must be https). Defaults to the production endpoint — override for non-prod tenants, e.g. https://tenant1.staging.streamsec.io. Unlike the other modules this is passed explicitly rather than derived from the streamsec provider, so vertex-ai-logging can be applied standalone without Stream Security API credentials."
  type        = string
  default     = "https://app.streamsec.io"
}

variable "vertex_ai_manage_apis" {
  description = "Whether the Vertex AI logging deployment enables the required project APIs. Set to false when the APIs are already enabled/owned elsewhere in the same project."
  type        = bool
  default     = true
}

variable "vertex_ai_secret_version_name" {
  description = "Optional override for the full Secret Manager version resource name the Vertex AI collector reads (e.g. projects/<p>/secrets/<s>/versions/latest). When empty, the shared secret created by the real-time-events module is used. Requires enable_real_time_events=true (or this override) so a token secret exists."
  type        = string
  default     = ""
}

variable "vertex_ai_project_id" {
  description = "GCP project ID for Vertex AI logging resources. Defaults to project_for_resources if empty."
  type        = string
  default     = ""
}

variable "vertex_ai_region" {
  description = "GCP region for the Vertex AI logging Cloud Function and Scheduler."
  type        = string
  default     = "us-central1"
}

variable "vertex_ai_create_bigquery_dataset" {
  description = "Whether to create the BigQuery dataset for Vertex AI logs. Set to false if it already exists."
  type        = bool
  default     = true
}

variable "vertex_ai_bigquery_dataset" {
  description = "BigQuery dataset ID for Vertex AI request-response logs."
  type        = string
  default     = "vertex_ai_logs"
}

variable "vertex_ai_bigquery_location" {
  description = "BigQuery dataset location for Vertex AI logs (must match the region where endpoints run)."
  type        = string
  default     = "US"
}

variable "vertex_ai_schedule_cron" {
  description = "Cloud Scheduler cron expression for Vertex AI log polling interval."
  type        = string
  default     = "*/5 * * * *"
}
