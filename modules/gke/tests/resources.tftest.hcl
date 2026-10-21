mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "111"
    }
  }
}
mock_provider "streamsec" {}

override_data {
  target = data.streamsec_gcp_project.this["p1"]
  values = {
    account_token = "tok-p1"
  }
}

override_data {
  target = data.streamsec_gcp_project.this["p2"]
  values = {
    account_token = "tok-p2"
  }
}

variables {
  org_level_sink        = true
  organization_id       = "123456789"
  project_for_resources = "p1"
  projects = {
    p1 = { project_id = "p1", name = "p1" }
    p2 = { project_id = "p2", name = "p2" }
  }
}

run "org_mode" {
  command = plan

  assert {
    condition     = length(google_logging_organization_sink.this) == 1 && length(google_logging_project_sink.this) == 0
    error_message = "Org mode needs one org sink and no project sinks."
  }
  assert {
    condition     = keys(google_cloudfunctions2_function.this) == ["p1"] && keys(google_pubsub_topic.this) == ["p1"]
    error_message = "Org mode deploys only in project_for_resources."
  }
  assert {
    condition     = google_cloudfunctions2_function.this["p1"].build_config[0].entry_point == "PubSubGKELogsCollection"
    error_message = "Wrong entry point."
  }
  assert {
    condition     = google_cloudfunctions2_function.this["p1"].event_trigger[0].retry_policy == "RETRY_POLICY_DO_NOT_RETRY"
    error_message = "Wrong retry policy."
  }
  assert {
    condition     = google_logging_organization_sink.this[0].filter == local.sink_filter && google_logging_organization_sink.this[0].include_children
    error_message = "Org sink must use the sink filter and include children."
  }
  assert {
    condition     = nonsensitive(google_secret_manager_secret_version.this["p1"].secret_data) == "tok-p1"
    error_message = "Secret must hold the project token."
  }
}

run "project_mode" {
  command = plan

  variables {
    org_level_sink = false
  }

  assert {
    condition     = length(google_logging_project_sink.this) == 2 && length(google_logging_organization_sink.this) == 0
    error_message = "Project mode needs one sink per project."
  }
  assert {
    condition     = length(google_pubsub_topic.this) == 2 && length(google_cloudfunctions2_function.this) == 2
    error_message = "Project mode needs a topic and function per project."
  }
  assert {
    condition     = nonsensitive(google_secret_manager_secret_version.this["p2"].secret_data) == "tok-p2"
    error_message = "Secret p2 must hold the p2 token."
  }
}

run "iam_scope" {
  command = plan

  assert {
    condition     = google_service_account_iam_member.pubsub_token_creator["p1"].member == "serviceAccount:service-111@gcp-sa-pubsub.iam.gserviceaccount.com"
    error_message = "Token creator must go to the Pub/Sub service agent."
  }
  assert {
    condition     = google_service_account_iam_member.pubsub_token_creator["p1"].role == "roles/iam.serviceAccountTokenCreator"
    error_message = "Wrong token creator role."
  }
  assert {
    condition     = google_cloud_run_v2_service_iam_member.invoker["p1"].role == "roles/run.invoker"
    error_message = "Wrong invoker role."
  }
}
