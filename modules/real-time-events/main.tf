data "streamsec_host" "this" {}

data "streamsec_gcp_project" "this" {
  for_each   = { for k, v in var.projects : k => v }
  project_id = each.value.project_id
}

resource "google_pubsub_topic" "this" {
  for_each                   = { for k, v in var.projects : k => v }
  name                       = try(each.value.pubsub_topic_name, var.pubsub_topic_name)
  message_retention_duration = var.topic_message_retention_duration
  labels                     = var.labels
  project                    = each.value.project_id
}

resource "google_logging_project_sink" "this" {
  for_each    = { for k, v in var.projects : k => v }
  name        = try(each.value.log_sink_name, var.log_sink_name)
  destination = "pubsub.googleapis.com/projects/${each.value.project_id}/topics/${google_pubsub_topic.this[each.key].name}"
  filter      = "logName=\"projects/${each.value.project_id}/logs/cloudaudit.googleapis.com%2Factivity\" AND protoPayload.methodName:* AND protoPayload.authenticationInfo.principalEmail:* AND NOT resource.type=\"k8s_cluster\""
  project     = each.value.project_id
  depends_on  = [google_pubsub_topic.this]
}

# permissions for the log sink
resource "google_pubsub_topic_iam_binding" "this" {
  for_each = { for k, v in var.projects : k => v }
  role     = "roles/pubsub.publisher"
  members  = [google_logging_project_sink.this[each.key].writer_identity]
  topic    = google_pubsub_topic.this[each.key].name
  project  = each.value.project_id
}

# function that triggers on log entries
resource "google_cloudfunctions_function" "this" {
  for_each              = { for k, v in var.projects : k => v }
  name                  = try(each.value.function_name, var.function_name)
  runtime               = var.function_runtime
  ingress_settings      = var.ingress_settings
  entry_point           = var.function_entry_point
  source_archive_bucket = var.source_bucket_name
  source_archive_object = var.source_archive_name
  timeout               = var.function_timeout
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.this[each.key].name
  }
  environment_variables = {
    API_URL   = data.streamsec_host.this.host
    API_TOKEN = data.streamsec_gcp_project.this[each.key].account_token
  }

  labels  = var.labels
  project = each.value.project_id
}
