provider "google" {
  project = var.google_project_id
  region  = var.google_region
}

# Read StreamSec provider credentials from Secret Manager
# Assumes the secret is a JSON with keys: host, username, password, workspace_id, api_token

data "google_secret_manager_secret_version" "streamsec" {
  secret  = var.streamsec_secret_name
  project = var.google_project_id
}

locals {
  streamsec_creds = jsondecode(data.google_secret_manager_secret_version.streamsec.secret_data)
}

provider "streamsec" {
  host         = try(local.streamsec_creds.host, null)
  username     = try(local.streamsec_creds.username, null)
  password     = try(local.streamsec_creds.password, null)
  workspace_id = try(local.streamsec_creds.workspace_id, null)
  api_token    = try(local.streamsec_creds.api_token, null)
}

# The root module declares the Mastercard `restapi` provider for the optional
# vertex-ai-logging module (not exposed through this wrapper). That provider
# refuses to load without a `uri`, even when nothing uses it, which broke every
# Infrastructure Manager preview since v2.9.0. A placeholder URI keeps init and
# plan working; no request is made unless Vertex AI logging is enabled.
provider "restapi" {
  uri = "https://${coalesce(var.google_region, "us-central1")}-aiplatform.googleapis.com"
}

module "streamsec_google_projects" {
  source = "../"

  # Main Module
  exclude_projects             = var.exclude_projects
  excluded_project_prefixes    = var.excluded_project_prefixes
  excluded_project_strings     = var.excluded_project_strings
  include_projects             = var.include_projects
  org_id                       = var.org_id # also used for response module and real time events module
  create_sa                    = var.create_sa
  sa_project_level_permissions = var.sa_project_level_permissions
  existing_sa_json_file_path   = var.existing_sa_json_file_path
  sa_display_name              = var.sa_display_name
  sa_description               = var.sa_description
  sa_account_id                = var.sa_account_id
  project_for_sa               = var.project_for_sa

  # Real Time Events Module
  enable_real_time_events              = var.enable_real_time_events
  use_secret_manager                   = var.use_secret_manager
  secret_name                          = var.secret_name
  org_level_sink                       = var.org_level_sink
  project_for_resources                = var.google_project_id
  use_existing_function_sa             = var.use_existing_function_sa
  function_service_account_id          = var.function_service_account_id
  grant_function_service_account_roles = var.grant_function_service_account_roles

  # Response Module
  response_enabled_projects      = var.response_enabled_projects
  exclude_runbooks               = var.exclude_runbooks
  response_org_level_permissions = var.response_org_level_permissions
  auto_grant_workflow_invoker    = var.auto_grant_workflow_invoker

  # GKE Module
  enable_gke_logs           = var.enable_gke_logs
  gke_org_level_sink        = var.gke_org_level_sink
  gke_include_projects      = var.gke_include_projects
  gke_include_clusters      = var.gke_include_clusters
  gke_exclude_clusters      = var.gke_exclude_clusters
  gke_region                = var.gke_region
  gke_build_service_account = var.gke_build_service_account
  gke_secret_name           = var.gke_secret_name
}

# The script grants the project resources role only in google_project_id.
resource "terraform_data" "gke_inputs" {
  count = var.enable_gke_logs && !coalesce(var.gke_org_level_sink, var.org_level_sink) ? 1 : 0
  lifecycle {
    precondition {
      condition     = toset(length(var.gke_include_projects) > 0 ? var.gke_include_projects : var.include_projects) == toset([var.google_project_id])
      error_message = "GKE project sinks work here only in google_project_id: set gke_include_projects = [google_project_id], or gke_org_level_sink = true."
    }
  }
}
