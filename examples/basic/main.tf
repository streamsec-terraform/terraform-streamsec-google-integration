provider "google" {
  project = "xxxxxxxx"
  region  = "xxxxxxx"
}

provider "streamsec" {
  host         = "xxxxx.streamsec.io" # required
  username     = "xxxxx@example.com"  # required unless api_token is set
  password     = "xxxxxxxxxxxx"       # required unless api_token is set
  workspace_id = "xxxxxxxxxxxx"       # required
  api_token    = "xxxxxxxxxxxx"       # required unless username and password are set
}


module "streamsec_google_projects" {
  source = "../../"
  # exclude_projects      = ["xxxxx", "xxxxx"] # will exclude these projects from the integration
  # include_projects      = ["xxxxxx", "xxxxxx"] # will include all projects in the organization if not set
  # org_id                = "xxxxxxxx" # required if create_sa is true
  # create_sa             = false
  # sa_display_name = "xxxxx" # optional, will only be used if create_sa is true
  # sa_description = "xxxxx" # optional, will only be used if create_sa is true
  # sa_account_id = "xxxxx" # required if create_sa is false and existing_sa_json_file_path is not set
  # project_for_sa = "xxxxx" # required if create_sa is false and existing_sa_json_file_path is not set
  # existing_sa_json_file_path = "/xxxx/xxxx" # if not set and create_sa is false, a new service account key will be created

  # enable_real_time_events = true
  # use_secret_manager = false
  # secret_name = "xxxxx"
  # org_level_sink = false
  # project_for_resources = "xxxxx" # required if org_level_sink is true
}
