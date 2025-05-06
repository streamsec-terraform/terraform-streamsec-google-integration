################################################################################
# Stream Security GCP Project Variables
################################################################################

variable "projects" {
  description = "A list of projects to create Service Accounts for."
  type        = any
  default     = {}
}

variable "org_integration" {
  description = "Organization Integration Boolean. If true, the Service Account will be created in the Organization and the projects will be discovered using the projects list API."
  type        = bool
  default     = false
}

variable "projects_filter" {
  description = "The filter to use to find projects in the Organization. you can also use the include_projects and exclude_projects variables to further filter the projects."
  type        = string
  default     = "name:*"
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
  description = "The Organization ID to create the Service Account in (REQUIRED if org_integration is true)."
  type        = string
  default     = null
}

variable "project_for_sa" {
  description = "The project to create the Service Account in (if not set and org_integration is true, will take provider project id)."
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
