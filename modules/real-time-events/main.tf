data "streamsec_host" "this" {}

data "google_project" "this" {
  count      = var.org_level_sink ? 1 : 0
  project_id = var.project_for_resources
}

data "google_client_config" "current" {}

data "streamsec_gcp_project" "this" {
  for_each   = { for k, v in var.projects : k => v }
  project_id = each.value.project_id
}

resource "google_pubsub_topic" "this" {
  for_each                   = var.org_level_sink ? { for k, v in var.projects : k => v if k == data.google_project.this[0].project_id } : { for k, v in var.projects : k => v }
  name                       = try(each.value.pubsub_topic_name, var.pubsub_topic_name)
  message_retention_duration = var.topic_message_retention_duration
  labels                     = var.labels
  project                    = each.value.project_id
}

resource "google_logging_organization_sink" "this" {
  count       = var.org_level_sink ? 1 : 0
  name        = var.log_sink_name
  destination = "pubsub.googleapis.com/projects/${data.google_project.this[0].project_id}/topics/${google_pubsub_topic.this[data.google_project.this[0].project_id].name}"
  filter = "${join(" OR ", [
    for project in var.projects :
    "(logName=\"projects/${project.project_id}/logs/cloudaudit.googleapis.com%2Factivity\" OR logName=\"projects/${project.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access\")"
  ])} OR (logName=\"organizations/${var.organization_id}/logs/cloudaudit.googleapis.com%2Factivity\" OR logName=\"organizations/${var.organization_id}/logs/cloudaudit.googleapis.com%2Fdata_access\") AND NOT protoPayload.methodName=~\"(?i).list\" AND protoPayload.methodName:* AND protoPayload.authenticationInfo.principalEmail:* AND NOT resource.type=\"k8s_cluster\""
  org_id           = var.organization_id
  depends_on       = [google_pubsub_topic.this]
  include_children = true
}

resource "google_logging_project_sink" "this" {
  for_each    = var.org_level_sink ? {} : { for k, v in var.projects : k => v }
  name        = try(each.value.log_sink_name, var.log_sink_name)
  destination = "pubsub.googleapis.com/projects/${each.value.project_id}/topics/${google_pubsub_topic.this[each.key].name}"
  filter      = "(logName=\"projects/${each.value.project_id}/logs/cloudaudit.googleapis.com%2Factivity\" OR (logName=\"projects/${each.value.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access\" AND NOT protoPayload.methodName=~\"(?i).list\")) AND protoPayload.methodName:* AND protoPayload.authenticationInfo.principalEmail:* AND NOT resource.type=\"k8s_cluster\""
  project     = each.value.project_id
  depends_on  = [google_pubsub_topic.this]
}

# permissions for the log sink
resource "google_pubsub_topic_iam_binding" "this" {
  for_each = var.org_level_sink ? { for k, v in var.projects : k => v if k == data.google_project.this[0].project_id } : { for k, v in var.projects : k => v }
  role     = "roles/pubsub.publisher"
  members  = var.org_level_sink ? [google_logging_organization_sink.this[0].writer_identity] : [google_logging_project_sink.this[each.key].writer_identity]
  topic    = google_pubsub_topic.this[each.key].name
  project  = each.value.project_id
}

# create the secret manager secret
resource "google_secret_manager_regional_secret" "this" {
  for_each  = var.use_secret_manager ? var.org_level_sink ? { for k, v in var.projects : k => v if k == data.google_project.this[0].project_id } : { for k, v in var.projects : k => v } : {}
  project   = each.value.project_id
  secret_id = var.secret_name
  location  = data.google_client_config.current.region
  labels    = var.labels
}

# create the secret manager secret version
resource "google_secret_manager_regional_secret_version" "this" {
  for_each    = var.use_secret_manager ? var.org_level_sink ? { for k, v in var.projects : k => v if k == data.google_project.this[0].project_id } : { for k, v in var.projects : k => v } : {}
  secret      = google_secret_manager_regional_secret.this[each.key].id
  secret_data = data.streamsec_gcp_project.this[each.key].account_token
}

# Gen2 Cloud Function that triggers on Pub/Sub log entries
resource "google_cloudfunctions2_function" "this" {
  for_each = var.org_level_sink ? { for k, v in var.projects : k => v if k == data.google_project.this[0].project_id } : { for k, v in var.projects : k => v }
  name     = try(each.value.function_name, var.function_name)
  location = data.google_client_config.current.region
  build_config {
    runtime     = var.function_runtime
    entry_point = var.function_entry_point
    source {
      storage_source {
        bucket = var.source_bucket_name
        object = var.source_archive_name
      }
    }
    environment_variables = merge(
      {
        API_URL = data.streamsec_host.this.host
      },
      var.use_secret_manager ? {
        SECRET_NAME = "projects/${each.value.project_id}/secrets/${var.secret_name}/versions/latest"
        } : {
        API_TOKEN = data.streamsec_gcp_project.this[each.key].account_token
      }
    )
  }
  service_config {
    timeout_seconds = var.function_timeout
    environment_variables = merge(
      {
        API_URL = data.streamsec_host.this.host
      },
      var.use_secret_manager ? {
        SECRET_NAME = "projects/${each.value.project_id}/locations/${data.google_client_config.current.region}/secrets/${var.secret_name}/versions/latest"
        } : {
        API_TOKEN = data.streamsec_gcp_project.this[each.key].account_token
      }
    )
    ingress_settings = var.ingress_settings
  }
  event_trigger {
    trigger_region = "us-central1"
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.this[each.key].id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
  labels  = var.labels
  project = each.value.project_id
}

resource "google_secret_manager_regional_secret_iam_member" "function_secret_access" {
  for_each  = var.use_secret_manager ? var.org_level_sink ? { for k, v in var.projects : k => v if k == data.google_project.this[0].project_id } : { for k, v in var.projects : k => v } : {}
  secret_id = var.secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_cloudfunctions2_function.this[each.key].service_config[0].service_account_email}"
  project   = each.value.project_id
}
