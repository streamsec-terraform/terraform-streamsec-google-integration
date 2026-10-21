mock_provider "google" {}
mock_provider "streamsec" {}
mock_provider "time" {}
mock_provider "restapi" {}

variables {
  enable_real_time_events = false
  enable_gke_logs         = true
  include_projects        = ["p1"]
  project_for_resources   = "p1"
  project_for_sa          = "p1"
}

override_data {
  target          = data.google_cloud_asset_search_all_resources.this
  override_during = plan
  values = {
    results = []
  }
}

override_resource {
  target          = module.gke[0].google_logging_organization_sink.this[0]
  override_during = plan
  values          = { writer_identity = "serviceAccount:org-sink" }
}

override_resource {
  target          = module.gke[0].google_logging_project_sink.this["p1"]
  override_during = plan
  values          = { writer_identity = "serviceAccount:project-sink" }
}

run "gke_follows_org_level_sink" {
  command = plan

  variables {
    org_id         = "123456789"
    org_level_sink = true
  }

  assert {
    condition     = length(module.gke[0].sink_writer_identities) == 1 && module.gke[0].sink_writer_identities["p1"] == "serviceAccount:org-sink"
    error_message = "org_level_sink = true must give the GKE module one organization sink."
  }
}

run "gke_override_project_mode" {
  command = plan

  variables {
    org_id         = null
    org_level_sink = true
    # Non-GKE inputs that need no org_id, so only GKE is under test.
    create_sa                    = false
    sa_project_level_permissions = true
    gke_org_level_sink           = false
  }

  assert {
    condition     = length(module.gke[0].sink_writer_identities) == 1 && module.gke[0].sink_writer_identities["p1"] == "serviceAccount:project-sink"
    error_message = "gke_org_level_sink = false must give one project sink and no organization sink."
  }
}

run "gke_secret_name_collision" {
  command = plan

  variables {
    org_id                  = "123456789"
    org_level_sink          = true
    enable_real_time_events = true
    gke_secret_name         = "stream-security-collection-token"
    regional_secret         = false
  }

  expect_failures = [terraform_data.gke_inputs]
}

run "gke_secret_name_same_regional" {
  command = plan

  variables {
    org_id                  = "123456789"
    org_level_sink          = true
    enable_real_time_events = true
    gke_secret_name         = "stream-security-collection-token"
    regional_secret         = true
  }

  assert {
    condition     = length(terraform_data.gke_inputs) == 1
    error_message = "A regional real-time secret of the same name must not clash with the GKE global secret."
  }
}
