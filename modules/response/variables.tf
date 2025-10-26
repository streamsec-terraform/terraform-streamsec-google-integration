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

variable "workflow_invoker_service_account" {
  description = "Service account email to grant roles/workflows.invoker permission for invoking workflows."
  type        = string
}

variable "auto_grant_workflow_invoker" {
  description = "If true, automatically grant roles/workflows.invoker permission to the specified service account."
  type        = bool
  default     = true
}
