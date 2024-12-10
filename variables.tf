################################################################################
# Stream Security GCP Project Variables
################################################################################

variable "projects" {
  description = "A list of projects to create Service Accounts for."
  type        = any
  default     = {}
}

variable "org_level_permissions" {
  description = "Boolean to determine if the Service Account should have Organization Level Permissions."
  type        = bool
  default     = false
}

variable "org_id" {
  description = "The Organization ID to create the Service Account in (REQUIRED if org_level_permissions is true)."
  type        = string
  default     = null
}

variable "project_for_sa" {
  description = "The project to create the Service Account in (if not set and org_level_permissions is true, will take provider project id)."
  type        = string
  default     = null
}

################################################################################
# Stream Security Application Registration Variables
################################################################################

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
