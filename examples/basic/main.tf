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
  projects = {
    staging = {
      project_id      = "xxxxxxxx"
      # flowlogs_bucket_name = "xxxxxxxx"
      # sa_account_id   = "xxxxxx"
      # sa_display_name = "xxxxxx"
    },
    production = {
      project_id      = "xxxxxxxx"
      # sa_account_id   = "xxxxxx"
      # sa_display_name = "xxxxxx"
    }
  }
}

