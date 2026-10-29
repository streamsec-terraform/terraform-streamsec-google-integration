mock_provider "google" {}
mock_provider "streamsec" {}

variables {
  organization_id       = "123456789"
  project_for_resources = "p1"
  projects = {
    p1 = { project_id = "p1" }
    p2 = { project_id = "p2" }
  }
}

run "org_sink_sends_list_calls" {
  command = plan

  variables {
    org_level_sink = true
  }

  assert {
    condition     = !strcontains(google_logging_organization_sink.this[0].filter, "(?i).list")
    error_message = "The organization sink must send list calls. The collection API keeps them off the events topic."
  }

  assert {
    condition     = strcontains(google_logging_organization_sink.this[0].filter, "(logName=\"projects/p2/logs/cloudaudit.googleapis.com%2Factivity\" OR logName=\"projects/p2/logs/cloudaudit.googleapis.com%2Fdata_access\")")
    error_message = "The organization sink must send each project's Admin Activity and Data Access logs."
  }
}

run "project_sinks_send_list_calls" {
  command = plan

  variables {
    org_level_sink = false
  }

  assert {
    condition     = google_logging_project_sink.this["p1"].filter == "(logName=\"projects/p1/logs/cloudaudit.googleapis.com%2Factivity\" OR logName=\"projects/p1/logs/cloudaudit.googleapis.com%2Fdata_access\") AND protoPayload.methodName:* AND protoPayload.authenticationInfo.principalEmail:* AND NOT resource.type=\"k8s_cluster\""
    error_message = "A project sink must send the project's Admin Activity and Data Access logs, list calls included."
  }
}
