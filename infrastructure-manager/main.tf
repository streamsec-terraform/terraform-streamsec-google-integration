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

module "streamsec_google_projects" {
  source = "../"

  # Main Module
  exclude_projects           = var.exclude_projects
  include_projects           = var.include_projects
  org_id                     = var.org_id # also used for response module and real time events module
  create_sa                  = var.create_sa
  existing_sa_json_file_path = var.existing_sa_json_file_path
  sa_display_name            = var.sa_display_name
  sa_description             = var.sa_description
  sa_account_id              = var.sa_account_id
  project_for_sa             = var.project_for_sa

  # Real Time Events Module
  enable_real_time_events = var.enable_real_time_events
  use_secret_manager      = var.use_secret_manager
  secret_name             = var.secret_name
  org_level_sink          = var.org_level_sink
  project_for_resources   = var.google_project_id
  use_existing_function_sa              = var.use_existing_function_sa
  function_service_account_id           = var.function_service_account_id
  grant_function_service_account_roles = var.grant_function_service_account_roles

  # Response Module
  response_enabled_projects      = var.response_enabled_projects
  exclude_runbooks               = var.exclude_runbooks
  response_org_level_permissions = var.response_org_level_permissions
  auto_grant_workflow_invoker    = var.auto_grant_workflow_invoker

  # GKE Module
  enable_gke_logs        = var.enable_gke_logs
  gke_bucket_name        = var.gke_bucket_name
  gke_bucket_location    = var.gke_bucket_location
  gke_api_url            = var.gke_api_url
  gke_secret_name        = var.gke_secret_name
  gke_streamsec_token    = var.gke_streamsec_token
}
