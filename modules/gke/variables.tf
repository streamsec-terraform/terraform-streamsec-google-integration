variable "project_id" {
  type        = string
  description = "Target GCP project ID (where bucket, secret, function live)."
}

variable "org_id" {
  type        = string
  description = "GCP organization ID (numeric). Used for org-level logging sink."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Cloud Function region."
}

variable "bucket_name" {
  type        = string
  description = "Bucket name to store logs (must be globally unique)."
}

variable "bucket_location" {
  type        = string
  default     = "US"
  description = "Bucket location/region or multi-region (e.g., US, EU, ASIA, us-central1)."
}

variable "api_url" {
  type        = string
  description = "Stream Security URL, e.g. https://YOUR_ENV.streamsec.io"
}

variable "secret_name" {
  type        = string
  default     = "streamsec-gke-logs-token"
  description = "Secret Manager secret name holding the StreamSec token."
}

variable "streamsec_token" {
  type        = string
  sensitive   = true
  description = "StreamSec collection token (stored in Secret Manager)."
}

variable "log_sink_name" {
  type        = string
  default     = "streamsec-gke-audit-logs"
  description = "Log router sink name."
}

variable "function_name" {
  type        = string
  default     = "stream-sec-gke-logs-collection"
  description = "Cloud Function name."
}

variable "function_runtime" {
  type        = string
  default     = "nodejs22"
  description = "Cloud Function runtime (guide uses nodejs22)."
}

variable "source_public_gcs_url" {
  type        = string
  default     = "gs://streamsec-public-artifacts/gcp-gke-logs-collection.zip"
  description = "Public artifact zip URL from StreamSec."
}
