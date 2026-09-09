variable "project_id" {
  description = "GCP project in which to deploy the collector."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,28}[a-z0-9])$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  description = "GCP region for the collector resources."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region such as us-central1."
  }
}

variable "stream_api_url" {
  description = "Stream Security tenant base URL."
  type        = string

  validation {
    condition     = can(regex("^https://[^[:space:]]+$", var.stream_api_url))
    error_message = "stream_api_url must be a full HTTPS URL."
  }
}

variable "stream_integration_token" {
  description = "Stream Security Palo Alto integration token."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.stream_integration_token)) > 0
    error_message = "stream_integration_token must not be empty."
  }
}

variable "stream_template_version" {
  description = "Git release ref used by Infrastructure Manager."
  type        = string
  default     = ""

  validation {
    condition     = var.stream_template_version == "" || can(regex("^[A-Za-z0-9._/-]+$", var.stream_template_version))
    error_message = "stream_template_version may contain only letters, digits, dots, underscores, slashes, and hyphens."
  }
}

variable "vpc_network" {
  description = "VPC network name or self-link selected by the wizard."
  type        = string

  validation {
    condition     = length(var.vpc_network) > 0 && can(regex("^[A-Za-z0-9._/@:-]+$", var.vpc_network))
    error_message = "vpc_network must be a non-empty network name or self-link."
  }
}

variable "subnet" {
  description = "Subnet name or self-link selected by the wizard."
  type        = string

  validation {
    condition     = length(var.subnet) > 0 && can(regex("^[A-Za-z0-9._/@:-]+$", var.subnet))
    error_message = "subnet must be a non-empty subnet name or self-link."
  }
}

variable "connector_cidr" {
  description = "Unused /28 IPv4 range allocated to the Serverless VPC Access connector."
  type        = string
  default     = "10.10.9.0/28"

  validation {
    condition = (
      can(cidrnetmask(var.connector_cidr)) &&
      can(regex("^[0-9.]+/28$", var.connector_cidr)) &&
      try(cidrhost(var.connector_cidr, 0) == split("/", var.connector_cidr)[0], false)
    )
    error_message = "connector_cidr must be a valid IPv4 /28 CIDR."
  }
}

variable "firewall_secret_names" {
  description = "Comma-delimited Secret Manager version resource names for firewall API keys."
  type        = string
  default     = ""

  validation {
    condition = var.firewall_secret_names == "" || alltrue([
      for name in split(",", var.firewall_secret_names) :
      can(regex("^projects/([0-9]+|[a-z][a-z0-9-]{4,28}[a-z0-9])/secrets/[A-Za-z0-9_-]+/versions/(latest|[0-9]+)$", trimspace(name)))
    ])
    error_message = "firewall_secret_names must be empty or a comma-delimited list of projects/<project>/secrets/<secret>/versions/<latest-or-number> names."
  }
}

variable "poll_schedule" {
  description = "Polling cron expression. The wizard omits it, so deployments default to every three minutes."
  type        = string
  default     = "*/3 * * * *"

  validation {
    condition     = contains(["* * * * *", "*/2 * * * *", "*/3 * * * *"], var.poll_schedule)
    error_message = "poll_schedule must run every one, two, or three minutes."
  }
}
