################################################################################
# Stream Security GCP Project Variables
################################################################################

variable "projects" {
  description = "A list of projects to create Service Accounts for."
  type        = any
  default     = {}
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
