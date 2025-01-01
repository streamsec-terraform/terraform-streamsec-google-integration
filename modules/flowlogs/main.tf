data "streamsec_host" "this" {}

data "streamsec_gcp_project" "this" {
  for_each   = { for k, v in var.projects : k => v }
  project_id = each.value.project_id
}

# function that triggers on log entries
resource "google_cloudfunctions_function" "this" {
  for_each = {
    for k, v in var.projects : k => v if contains(keys(v), "flowlogs_bucket_name")
  }
  name                  = try(each.value.function_name, var.function_name)
  runtime               = var.function_runtime
  entry_point           = var.function_entry_point
  source_archive_bucket = var.source_bucket_name
  source_archive_object = var.source_archive_name
  ingress_settings      = var.ingress_settings
  timeout               = var.function_timeout
  event_trigger {
    event_type = "google.storage.object.finalize"
    resource   = each.value.flowlogs_bucket_name
  }
  environment_variables = {
    API_URL   = data.streamsec_host.this.host
    API_TOKEN = data.streamsec_gcp_project.this[each.key].account_token
  }

  labels  = var.labels
  project = each.value.project_id
}
