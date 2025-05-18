provider "google" {
  project = var.google_project_id
  region  = var.google_region
}

provider "streamsec" {
  host         = var.streamsec_host
  username     = var.streamsec_username
  password     = var.streamsec_password
  workspace_id = var.streamsec_workspace_id
  api_token    = var.streamsec_api_token
}


module "streamsec_google_projects" {
  source                     = "../"
  projects_filter            = var.projects_filter
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
}
