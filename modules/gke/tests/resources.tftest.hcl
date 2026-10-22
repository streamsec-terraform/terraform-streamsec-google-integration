mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "111"
    }
  }
}
mock_provider "streamsec" {
  mock_data "streamsec_host" {
    defaults = {
      host = "api.example.test"
    }
  }
}
mock_provider "time" {}
mock_provider "random" {}

override_resource {
  target          = random_id.suffix
  override_during = plan
  values          = { hex = "0a1b2c3d" }
}

override_resource {
  target          = google_pubsub_topic.this["p1"]
  override_during = plan
  values          = { id = "projects/p1/topics/streamsec-gke-audit-logs-0a1b2c3d" }
}

override_resource {
  target          = google_pubsub_topic.this["p2"]
  override_during = plan
  values          = { id = "projects/p2/topics/streamsec-gke-audit-logs-0a1b2c3d" }
}

override_resource {
  target          = google_logging_organization_sink.this[0]
  override_during = plan
  values          = { writer_identity = "serviceAccount:org-sink" }
}

override_resource {
  target          = google_logging_project_sink.this["p1"]
  override_during = plan
  values          = { writer_identity = "serviceAccount:sink-p1" }
}

override_resource {
  target          = google_logging_project_sink.this["p2"]
  override_during = plan
  values          = { writer_identity = "serviceAccount:sink-p2" }
}

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
  acked_project_ids     = { p1 = "p1", p2 = "p2" }
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
    condition     = length(split(",", time_sleep.api_propagation.triggers.apis)) == 9 && startswith(time_sleep.api_propagation.triggers.apis, "p1/")
    error_message = "Org mode needs one API wait, on project_for_resources' APIs."
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
  assert {
    condition     = google_pubsub_topic_iam_member.sink_publisher["p1"].member == google_logging_organization_sink.this[0].writer_identity
    error_message = "Topic publisher must be the org sink writer identity."
  }
  assert {
    condition     = toset(keys(output.sink_names)) == toset(["p1"]) && output.sink_names["p1"] == "streamsec-gke-audit-logs-pubsub-0a1b2c3d" && toset(keys(output.secret_ids)) == toset(["p1"])
    error_message = "Org mode outputs one sink name and one secret, keyed by project_for_resources."
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
    condition     = length(split(",", time_sleep.api_propagation.triggers.apis)) == 18
    error_message = "The API wait must cover the APIs of every project, so an added project waits again."
  }
  assert {
    condition     = nonsensitive(google_secret_manager_secret_version.this["p2"].secret_data) == "tok-p2"
    error_message = "Secret p2 must hold the p2 token."
  }
  assert {
    condition     = google_pubsub_topic_iam_member.sink_publisher["p1"].member == "serviceAccount:sink-p1" && google_pubsub_topic_iam_member.sink_publisher["p2"].member == "serviceAccount:sink-p2"
    error_message = "Each topic publisher must be its own sink writer identity."
  }
  assert {
    condition     = google_logging_project_sink.this["p1"].destination == "pubsub.googleapis.com/projects/p1/topics/streamsec-gke-audit-logs-0a1b2c3d" && google_logging_project_sink.this["p2"].destination == "pubsub.googleapis.com/projects/p2/topics/streamsec-gke-audit-logs-0a1b2c3d"
    error_message = "Each project sink must target its own topic."
  }
  assert {
    condition     = toset(keys(output.sink_names)) == toset(["p1", "p2"]) && toset(keys(output.secret_ids)) == toset(["p1", "p2"]) && output.sink_writer_identities["p2"] == "serviceAccount:sink-p2"
    error_message = "Project mode outputs a sink name, secret and writer identity per project."
  }
}

run "function_config" {
  command = plan

  variables {
    build_service_account = "projects/p1/serviceAccounts/builder@p1.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_cloudfunctions2_function.this["p1"].service_config[0].environment_variables.API_URL == data.streamsec_host.this.host && data.streamsec_host.this.host == "api.example.test"
    error_message = "API_URL must be the bare Stream Security host."
  }
  assert {
    condition     = google_cloudfunctions2_function.this["p1"].service_config[0].environment_variables.SECRET_NAME == "projects/p1/secrets/streamsec-gke-logs-token-0a1b2c3d/versions/latest"
    error_message = "Wrong SECRET_NAME."
  }
  assert {
    condition     = google_cloudfunctions2_function.this["p1"].service_config[0].ingress_settings == "ALLOW_INTERNAL_ONLY"
    error_message = "Function ingress must be internal only."
  }
  assert {
    condition     = google_cloudfunctions2_function.this["p1"].build_config[0].service_account == "projects/p1/serviceAccounts/builder@p1.iam.gserviceaccount.com"
    error_message = "build_service_account must set the build service account."
  }
}

run "build_service_account_per_project" {
  command = plan

  variables {
    org_level_sink        = false
    build_service_account = "projects/{project}/serviceAccounts/builder@{project}.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_cloudfunctions2_function.this["p2"].build_config[0].service_account == "projects/p2/serviceAccounts/builder@p2.iam.gserviceaccount.com" && google_cloudfunctions2_function.this["p1"].build_config[0].service_account == "projects/p1/serviceAccounts/builder@p1.iam.gserviceaccount.com"
    error_message = "{project} in build_service_account must become each deploy project ID."
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

run "names_suffix_and_limits" {
  command = plan

  variables {
    org_level_sink = false
  }

  # GCP limits: service account ID 30, Cloud Run service (function) 49, sink 100, topic and secret 255.
  assert {
    condition = alltrue(flatten([for k in ["p1", "p2"] : [
      length(google_service_account.this[k].account_id) <= 30 && endswith(google_service_account.this[k].account_id, "-0a1b2c3d"),
      length(google_cloudfunctions2_function.this[k].name) <= 49 && endswith(google_cloudfunctions2_function.this[k].name, "-0a1b2c3d"),
      length(google_logging_project_sink.this[k].name) <= 100 && endswith(google_logging_project_sink.this[k].name, "-0a1b2c3d"),
      length(google_pubsub_topic.this[k].name) <= 255 && endswith(google_pubsub_topic.this[k].name, "-0a1b2c3d"),
      length(google_secret_manager_secret.this[k].secret_id) <= 255 && endswith(google_secret_manager_secret.this[k].secret_id, "-0a1b2c3d"),
    ]]))
    error_message = "Every GKE resource name must end with the random suffix and fit its GCP limit."
  }
  assert {
    condition     = google_cloudfunctions2_function.this["p1"].name == google_cloudfunctions2_function.this["p2"].name
    error_message = "All projects share one suffix."
  }
}

run "secret_name_as_given" {
  command = plan

  variables {
    secret_name = "my-gke-token"
  }

  assert {
    condition     = google_secret_manager_secret.this["p1"].secret_id == "my-gke-token" && google_cloudfunctions2_function.this["p1"].service_config[0].environment_variables.SECRET_NAME == "projects/p1/secrets/my-gke-token/versions/latest"
    error_message = "A secret_name that is set must be used as given."
  }
}
