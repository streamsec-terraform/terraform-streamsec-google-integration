variable "projects" {
  description = "A list of project IDs to create response resources for."
  type        = list(string)
}

variable "org_level_permissions" {
  description = "If true, create service accounts and custom roles at organization level. If false, create them at project level."
  type        = bool
  default     = true
}

variable "organization_id" {
  description = "The organization ID to use for org-level service accounts and roles. Required if org_level_permissions is true."
  type        = string
  default     = ""
}

variable "exclude_runbooks" {
  description = "List of runbook names to exclude from deployment. Useful for disabling specific remediations."
  type        = list(string)
  default     = []
}
