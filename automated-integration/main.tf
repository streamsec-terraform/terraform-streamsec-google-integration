provider "google" {
  project = var.google_project_id
  region  = var.google_region
}

resource "google_pubsub_topic" "project_events" {
  name    = var.pubsub_topic_name
  project = var.google_project_id
}

resource "google_logging_organization_sink" "project_create" {
  name             = var.log_sink_name
  org_id           = var.org_id
  destination      = "pubsub.googleapis.com/projects/${var.google_project_id}/topics/${google_pubsub_topic.project_events.name}"
  filter           = "(protoPayload.methodName=\"CreateProject\" AND protoPayload.resourceName:\"projects\") OR protoPayload.methodName=\"DeleteProject\""
  include_children = true
}

resource "google_pubsub_topic_iam_binding" "allow_sink_publish" {
  topic   = google_pubsub_topic.project_events.name
  role    = "roles/pubsub.publisher"
  members = [google_logging_organization_sink.project_create.writer_identity]
  project = var.google_project_id
}

resource "google_cloudfunctions2_function" "handle_project_create" {
  name     = var.function_name
  location = var.google_region
  project  = var.google_project_id
  build_config {
    runtime     = var.function_runtime
    entry_point = var.function_entry_point
    source {
      storage_source {
        bucket = var.function_source_bucket
        object = var.function_source_object
      }
    }
  }
  service_config {
    timeout_seconds       = var.function_timeout
    ingress_settings      = var.ingress_settings
    service_account_email = var.service_account_email
    environment_variables = {
      INFRA_MANAGER_DEPLOYMENT_NAME = var.infra_manager_deployment_name
    }
  }
  event_trigger {
    trigger_region = var.google_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.project_events.id
    retry_policy   = var.retry_policy
  }
}
