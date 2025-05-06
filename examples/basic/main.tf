provider "google" {
  project = "xxxxxxxx"
  region  = "xxxxxxx"
}

provider "streamsec" {
  host         = "xxxxx.streamsec.io"
  username     = "xxxxx@example.com"
  password     = "xxxxxxxxxxxx"
  workspace_id = "xxxxxxxxxxxx"
}


module "streamsec_google_projects" {
  source = "../../"
  # enable_real_time_events = true
  # org_id                = "xxxxxxxx"
  # create_sa             = false
  # existing_sa_json_file_path = "/xxxx/xxxx"
  # exclude_projects      = ["xxxxx", "xxxxx"] # will exclude these projects from the integration
  # include_projects      = ["xxxxxx", "xxxxxx"] # will include all projects in the organization if not set
}
