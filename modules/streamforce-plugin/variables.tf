################################################################################
# StreamForce custom-plugin — Cloud Run (Gen2 Function) deployment
################################################################################

variable "project_id" {
  description = "The GCP project to deploy the plugin function into."
  type        = string
}

variable "region" {
  description = "The Cloud Run region to deploy the plugin function in."
  type        = string
  default     = "us-central1"
}

variable "plugin_id" {
  description = "The Stream Security plugin id (used for naming and the acknowledge callback)."
  type        = string
}

variable "artifact_url" {
  description = "Public URL of the plugin deploy package (zip), hosted by Stream Security. The module stages it into a bucket in your project."
  type        = string
}

variable "plugin_token" {
  description = "Per-plugin Stream Security callback token."
  type        = string
  sensitive   = true
}

variable "platform_url" {
  description = "Stream Security platform base URL (used for the acknowledge callback and the function's api_key fetch)."
  type        = string
}

variable "invoker_sa_email" {
  description = "Email of the Stream Security integration service account that is granted run.invoker on the function — the identity Stream signs its tool calls with."
  type        = string
}

variable "plugin_env" {
  description = "The plugin's environment values. Passed straight into the function's env — never through the Stream platform."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "runtime" {
  description = "Cloud Functions Node runtime."
  type        = string
  default     = "nodejs20"
}

variable "available_memory" {
  description = "Memory for the plugin function."
  type        = string
  default     = "256Mi"
}

variable "timeout_seconds" {
  description = "Request timeout for the plugin function."
  type        = number
  default     = 60
}

variable "labels" {
  description = "Labels to apply to the created resources."
  type        = map(string)
  default     = {}
}
