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
  source                     = "../"
  exclude_projects           = var.exclude_projects
  include_projects           = var.include_projects
  enable_real_time_events    = var.enable_real_time_events
  org_id                     = var.org_id
  create_sa                  = var.create_sa
  sa_display_name            = var.sa_display_name
  sa_description             = var.sa_description
  sa_account_id              = var.sa_account_id
  project_for_sa             = var.project_for_sa
  existing_sa_json_file_path = var.existing_sa_json_file_path
  use_secret_manager         = var.use_secret_manager
  secret_name                = var.secret_name
  org_level_sink             = var.org_level_sink
  project_for_resources      = var.google_project_id
}
