# Stream Security — GCP volume scanner hub access: module inputs.

variable "hub_project_id" {
  type        = string
  description = "The hub: the project whose volume scanner, deployed by Stream with modules/volume-scanner, also scans other projects of the organization."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.hub_project_id))
    error_message = "hub_project_id must be a GCP project ID: 6 to 30 lowercase letters, digits or hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "scanner_service_account_email" {
  type        = string
  description = "The hub scanner's service account. Null, the default, means streamsec-volume-scanner@<hub_project_id>.iam.gserviceaccount.com, the one modules/volume-scanner creates. Set it for a scanner deployed with a name_suffix, whose account ends in the suffix."
  default     = null
  validation {
    condition     = var.scanner_service_account_email == null || can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\\.iam\\.gserviceaccount\\.com$", var.scanner_service_account_email))
    error_message = "scanner_service_account_email must be a service account's email, <account>@<project>.iam.gserviceaccount.com."
  }
}

variable "org_id" {
  type        = string
  description = "The organization's numeric ID. The custom role is defined there, and the folders and projects in grant_on must belong to it."
  validation {
    condition     = can(regex("^[0-9]{1,20}$", var.org_id))
    error_message = "org_id must be the organization's numeric ID, digits only, without \"organizations/\"."
  }
}

variable "grant_on" {
  type = object({
    organization = optional(bool, false)
    folder_ids   = optional(list(string), [])
    project_ids  = optional(list(string), [])
  })
  description = "Where the role is granted, exactly one of: { organization = true }, the default, for every project of the organization, including ones created later; { folder_ids = [...] } for the projects under those folders; or { project_ids = [...] } for those projects only, so IAM matches the projects selected in Stream exactly."
  default     = { organization = true }
  nullable    = false

  # An empty list is not read as the organization: a list computed empty by
  # mistake would widen the grant to every project.
  validation {
    condition     = length([for on in [var.grant_on.organization, length(var.grant_on.folder_ids) > 0, length(var.grant_on.project_ids) > 0] : on if on]) == 1
    error_message = "grant_on must name exactly one place: { organization = true }, { folder_ids = [...] } with at least one folder, or { project_ids = [...] } with at least one project."
  }

  validation {
    condition     = alltrue([for id in var.grant_on.folder_ids : can(regex("^[0-9]{1,20}$", id))])
    error_message = "grant_on.folder_ids must be numeric folder IDs, digits only, without \"folders/\"."
  }

  validation {
    condition     = alltrue([for id in var.grant_on.project_ids : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", id))])
    error_message = "grant_on.project_ids must be GCP project IDs: 6 to 30 lowercase letters, digits or hyphens, starting with a letter and not ending with a hyphen."
  }
}
