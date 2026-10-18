mock_provider "google" {}
mock_provider "streamsec" {}
mock_provider "time" {}
mock_provider "restapi" {}

variables {
  org_id                  = "123456789"
  enable_real_time_events = false
}

override_data {
  target          = data.google_cloud_asset_search_all_resources.this
  override_during = plan
  values = {
    results = []
  }
}

run "created_sa_home_project" {
  command = plan

  variables {
    create_sa = true
  }

  override_resource {
    target          = google_service_account.org
    override_during = plan
    values = {
      email = "stream-security@sa-home-project.iam.gserviceaccount.com"
    }
  }

  assert {
    condition     = alltrue([for s in google_project_service.scan_quota_apis : s.project == "sa-home-project"])
    error_message = "The client-based APIs must be enabled on the created service account's home project."
  }

  assert {
    condition = toset(keys(google_project_service.scan_quota_apis)) == toset([
      "sqladmin.googleapis.com",
      "cloudkms.googleapis.com",
      "bigtableadmin.googleapis.com",
      "apikeys.googleapis.com",
      "appengine.googleapis.com",
      "cloudidentity.googleapis.com",
      "accesscontextmanager.googleapis.com",
      "orgpolicy.googleapis.com",
      "serviceusage.googleapis.com",
      "firebaserules.googleapis.com",
      "bigquery.googleapis.com",
    ])
    error_message = "Exactly the 11 client-based scan APIs must be enabled."
  }

  assert {
    condition     = alltrue([for s in google_project_service.scan_quota_apis : s.disable_on_destroy == false])
    error_message = "Removing the integration must never disable APIs the customer may rely on."
  }
}

run "existing_sa_json_home_project" {
  command = plan

  variables {
    create_sa                  = false
    existing_sa_json_file_path = "tests/fixtures/byo_sa.json"
    project_for_sa             = "unrelated-project"
  }

  assert {
    condition     = alltrue([for s in google_project_service.scan_quota_apis : s.project == "byo-home-project"])
    error_message = "A bring-your-own key must enable the APIs on the key's own home project, read from its client_email."
  }
}

run "non_standard_email_falls_back_to_project_for_sa" {
  command = plan

  variables {
    create_sa      = true
    project_for_sa = "sa-home-project"
  }

  override_resource {
    target          = google_service_account.org
    override_during = plan
    values = {
      email = "123456789-compute@developer.gserviceaccount.com"
    }
  }

  assert {
    condition     = alltrue([for s in google_project_service.scan_quota_apis : s.project == "sa-home-project"])
    error_message = "An email without a project domain must fall back to project_for_sa."
  }
}

run "non_standard_email_without_project_for_sa_fails" {
  command = plan

  variables {
    create_sa = true
  }

  override_resource {
    target          = google_service_account.org
    override_during = plan
    values = {
      email = "123456789-compute@developer.gserviceaccount.com"
    }
  }

  expect_failures = [google_project_service.scan_quota_apis]
}
