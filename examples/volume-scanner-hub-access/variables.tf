variable "hub_project_ids" {
  type        = set(string)
  description = "The projects whose volume scanner also scans the other projects of the organization."
}

variable "org_id" {
  type        = string
  description = "The organization's numeric ID."
}

variable "create_role" {
  type        = bool
  description = "Create and manage the organization's streamsecVolumeScannerTarget role. False when Stream's console command created it, or another stack manages it."
  default     = true
}
