# Mirrors modules/volume-scanner so --input-values can set them on the root.
variable "project_id" {
  type        = string
  description = "GCP project to scan."
}

variable "region" {
  type        = string
  description = "Region for the orchestrator Cloud Run Job + Cloud Scheduler."
  default     = "us-central1"
}

variable "scanner_image" {
  type        = string
  description = "Public scanner container image (orchestrator + worker), in a GCP-pullable registry."
  default     = "us-docker.pkg.dev/stream-secops-project/streamsec-public/volume-scanner:latest"
}

variable "stream_api_url" {
  type        = string
  description = "Stream Security tenant API URL, e.g. https://<tenant>.<domain>."
}

variable "stream_customer_id" {
  type        = string
  description = "Stream Security workspace (customer) id."
}

variable "stream_ack_token" {
  type        = string
  description = "Per-deployment acknowledge token (authenticates install callback)."
  sensitive   = true
}

variable "stream_collection_token" {
  type        = string
  description = "Per-customer collection token (authenticates scan reports)."
  sensitive   = true
}

variable "scan_language_packages" {
  type        = string
  description = "Scan OS/language packages for CVEs (COLLECTOR_SCAN_LANGUAGE_PACKAGES). \"true\" or \"false\" (case-insensitive)."
  default     = "true"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_language_packages))
    error_message = "scan_language_packages must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_secrets" {
  type        = string
  description = "Scan for secrets/credentials on the volume (COLLECTOR_SCAN_SECRETS). \"true\" or \"false\" (case-insensitive)."
  default     = "false"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_secrets))
    error_message = "scan_secrets must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_ai_workloads" {
  type        = string
  description = "Scan for AI/ML models, frameworks, and workloads (COLLECTOR_SCAN_AI_WORKLOADS). \"true\" or \"false\" (case-insensitive)."
  default     = "false"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_ai_workloads))
    error_message = "scan_ai_workloads must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_cloud_run" {
  type        = string
  description = "Scan the images of Cloud Run services, which include Cloud Run functions and gen2 Cloud Functions (workload kind cloudrun). \"true\" or \"false\" (case-insensitive)."
  default     = "true"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_cloud_run))
    error_message = "scan_cloud_run must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_cloud_run_jobs" {
  type        = string
  description = "Scan the images of Cloud Run jobs (workload kind cloudrunjobs). \"true\" or \"false\" (case-insensitive)."
  default     = "true"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_cloud_run_jobs))
    error_message = "scan_cloud_run_jobs must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_cloud_functions" {
  type        = string
  description = "Scan gen1 Cloud Functions from their deployed source (workload kind cloudfunctions). Gen2 functions are Cloud Run services and are covered by scan_cloud_run. \"true\" or \"false\" (case-insensitive)."
  default     = "true"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_cloud_functions))
    error_message = "scan_cloud_functions must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_workload_only" {
  type        = string
  description = "Scan only the workloads selected above, and no VM disks (COLLECTOR_WORKLOAD_ONLY). Needs at least one workload kind on, and a scanner image with GCP workload scanning (newer than v0.5.21): with an older image a workload-only run scans nothing. \"true\" or \"false\" (case-insensitive)."
  default     = "false"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_workload_only))
    error_message = "scan_workload_only must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "stream_template_version" {
  type        = string
  description = "Module release tag, echoed back in the install acknowledgement so Stream records which version was actually applied. Empty leaves the deployment's version unknown rather than wrong."
  default     = ""
}

variable "name_suffix" {
  type        = string
  description = "Suffix for every resource name, to run a second instance of the scanner in the same project, for example \"-stg\" for one reporting to a staging workspace. Empty, the default, keeps the original names. A suffixed instance must be workload-only (scan_workload_only = \"true\"): disk-scanning snapshots are not scoped to an instance, so two disk scanners in one project would delete each other's snapshots."
  default     = ""
  validation {
    condition     = can(regex("^(-[a-z0-9]{1,5})?$", var.name_suffix))
    error_message = "name_suffix must be empty, or a hyphen followed by 1 to 5 lowercase letters or digits, which keeps the service account id within 30 characters."
  }
}
