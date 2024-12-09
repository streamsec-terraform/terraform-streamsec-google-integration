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
  projects = {
    staging = {
      project_id      = "xxxxxxxx"
      sa_account_id   = "xxxxxx"
      sa_display_name = "xxxxxx"
    },
    production = {
      project_id      = "xxxxxxxx"
      sa_account_id   = "xxxxxx"
      sa_display_name = "xxxxxx"
    }
  }
}

module "streamsec_real_time_events" {
  source     = "../../modules/real-time-events"
  projects   = module.streamsec_google_projects.projects
  depends_on = [module.streamsec_google_projects]
}
