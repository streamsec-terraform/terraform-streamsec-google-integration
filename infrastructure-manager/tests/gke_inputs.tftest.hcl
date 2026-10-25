mock_provider "google" {}
mock_provider "streamsec" {}
mock_provider "time" {}
mock_provider "restapi" {}

variables {
  google_project_id = "p1"
  include_projects  = ["p1", "p2"]
  org_id            = "123456789"
  enable_gke_logs   = true
}

override_data {
  target = data.google_secret_manager_secret_version.streamsec
  values = {
    secret_data = "{}"
  }
}

override_data {
  target          = module.streamsec_google_projects.data.google_cloud_asset_search_all_resources.this
  override_during = plan
  values = {
    results = []
  }
}

run "gke_project_sinks_other_projects" {
  command = plan

  variables {
    gke_org_level_sink = false
  }

  expect_failures = [terraform_data.gke_inputs]
}

run "gke_project_sink_in_google_project_id" {
  command = plan

  variables {
    gke_org_level_sink   = false
    gke_include_projects = ["p1"]
  }

  assert {
    condition     = length(terraform_data.gke_inputs) == 1
    error_message = "A project sink in google_project_id only must pass."
  }
}

run "gke_org_sink" {
  command = plan

  assert {
    condition     = length(terraform_data.gke_inputs) == 0
    error_message = "An org sink needs no project check."
  }
}
