
################################################################################
# Google Provider Variables
################################################################################
variable "google_project_id" {
  description = "The Google Project ID to use for the integration."
  type        = string
}

variable "google_region" {
  description = "The Google Region to use for the integration."
  type        = string
}

################################################################################
# Stream Security Provider Variables
################################################################################

variable "streamsec_secret_name" {
  description = "The name of the Secret Manager secret containing the StreamSec provider credentials (JSON with host, username, password, workspace_id, api_token)."
  type        = string
  default     = "stream-security"
}

variable "exclude_projects" {
  description = "A list of projects to exclude from the Organization Integration."
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
  default     = "stream-security"
}

variable "org_level_sink" {
  description = "If true, create a single org-level log sink, topic, and function. Otherwise, create per-project."
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
