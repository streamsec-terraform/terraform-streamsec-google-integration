provider "streamsec" {
  host         = var.streamsec_host
  username     = var.streamsec_username
  password     = var.streamsec_password
  workspace_id = var.streamsec_workspace_id
  api_token    = var.streamsec_api_token
}


module "streamsec_google_projects" {
  source                     = "../"
  projects_filter            = "name:*" # default to all projects can be further filtered by include_projects and exclude_projects
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
