variable "org_level_sink" {
  type        = bool
  description = "true: one organization sink and one deployment in project_for_resources. false: a sink and a deployment in each GKE project."
}

variable "organization_id" {
  type        = string
  default     = null
  description = "GCP organization ID. Required when org_level_sink is true."
}

variable "project_for_resources" {
  type        = string
  default     = ""
  description = "Org mode: integrated project that holds the topic, function and secret."
}

variable "projects" {
  type = map(object({
    project_id = string
    name       = string
  }))
  description = "Integrated projects."
}

variable "acked_project_ids" {
  type        = map(string)
  description = "Project ID per integrated project; unknown until its ack exists."
}

variable "include_projects" {
  type        = list(string)
  default     = []
  description = "GKE projects (subset of projects). Empty means all integrated projects (org mode: the whole organization)."
}

variable "include_clusters" {
  type        = list(string)
  default     = []
  description = "Cluster names to collect. Empty means all clusters."
}

variable "exclude_clusters" {
  type        = list(string)
  default     = []
  description = "Cluster names to skip."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Function and trigger region."
}

variable "build_service_account" {
  type        = string
  default     = null
  description = "Service account that builds the function (projects/<project>/serviceAccounts/<email>); {project} is replaced by each deploy project ID. Null uses the project default."
}

variable "secret_name" {
  type        = string
  default     = null
  description = "Secret Manager secret name for the Stream Security token. Null: streamsec-gke-logs-token-<random suffix>."
}

variable "source_bucket" {
  type        = string
  default     = "streamsec-production-public-artifacts"
  description = "Bucket with the function source zip."
}

variable "source_object" {
  type        = string
  default     = "gcp-gke-logs-collection.zip"
  description = "Function source zip object name."
}
