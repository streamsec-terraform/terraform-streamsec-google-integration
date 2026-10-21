variable "hub_project_id" {
  type        = string
  description = "The project whose volume scanner also scans the other projects of the organization."
}

variable "org_id" {
  type        = string
  description = "The organization's numeric ID."
}
