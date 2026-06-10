data "streamsec_host" "this" {}

locals {
  function_name = "${var.name_prefix}-vertex-ai-collector"
  sa_name       = "${var.name_prefix}-vtx-collector"
  bucket_name   = "${var.name_prefix}-vtx-collector-state-${var.project_id}"
}

# --- Service Account ---

resource "google_service_account" "collector" {
  project      = var.project_id
  account_id   = local.sa_name
  display_name = "Stream Security Vertex AI Log Collector"
}

resource "google_project_iam_member" "bq_reader" {
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.collector.email}"
}

resource "google_project_iam_member" "bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.collector.email}"
}

resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.collector.email}"
}

# --- GCS Bucket (watermark state) ---

resource "google_storage_bucket" "state" {
  project                     = var.project_id
  name                        = local.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  labels = var.labels

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }
}

resource "google_storage_bucket_iam_member" "state_writer" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.collector.email}"
}

# --- BigQuery Dataset & Table (optional) ---

resource "google_bigquery_dataset" "vertex_ai_logs" {
  count = var.create_bigquery_dataset ? 1 : 0

  project                    = var.project_id
  dataset_id                 = var.bigquery_dataset
  location                   = var.bigquery_location
  default_table_expiration_ms = var.bigquery_log_retention_days * 86400000
  delete_contents_on_destroy = true

  labels = var.labels

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  access {
    role          = "READER"
    user_by_email = google_service_account.collector.email
  }
}

# Note: Vertex AI request-response logging creates its own date-sharded tables
# (e.g., predictions_YYYYMMDD) in the dataset automatically. No need to pre-create a table.

# --- Cloud Function Source ---

data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "${path.module}/function_source"
  output_path = "${path.module}/.build/function_source.zip"
}

resource "google_storage_bucket_object" "function_source" {
  name   = "function_source_${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.state.name
  source = data.archive_file.function_source.output_path
}

# --- Cloud Function (2nd Gen) ---

resource "google_cloudfunctions2_function" "vertex_ai_collector" {
  project  = var.project_id
  name     = local.function_name
  location = var.region

  depends_on = [google_project_service.required_apis]

  labels = var.labels

  build_config {
    runtime     = "python314"
    entry_point = "handler"

    source {
      storage_source {
        bucket = google_storage_bucket.state.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    min_instance_count    = 0
    available_memory      = "${var.function_memory_mb}M"
    timeout_seconds       = var.function_timeout_seconds
    service_account_email = google_service_account.collector.email
    ingress_settings      = "ALLOW_INTERNAL_ONLY"

    environment_variables = {
      GCP_PROJECT_ID          = var.project_id
      BIGQUERY_DATASET        = var.bigquery_dataset
      BIGQUERY_TABLE          = var.bigquery_table
      API_URL                 = data.streamsec_host.this.host
      STATE_BUCKET            = google_storage_bucket.state.name
      BATCH_SIZE              = tostring(var.batch_size)
      SECRET_NAME             = var.secret_name
    }
  }
}

# --- Cloud Scheduler ---

resource "google_cloud_scheduler_job" "poll_trigger" {
  project   = var.project_id
  name      = "${var.name_prefix}-vertex-ai-poll"
  region    = var.region
  schedule  = var.schedule_cron
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.vertex_ai_collector.url

    oidc_token {
      service_account_email = google_service_account.collector.email
      audience              = google_cloudfunctions2_function.vertex_ai_collector.url
    }
  }

  retry_config {
    retry_count          = 1
    min_backoff_duration = "10s"
    max_backoff_duration = "60s"
  }
}

# --- Enable request-response logging on publisher model ---

resource "null_resource" "enable_logging" {
  count = var.enable_request_response_logging ? 1 : 0

  triggers = {
    model         = var.vertex_ai_model
    sampling_rate = var.logging_sampling_rate
    dataset       = var.bigquery_dataset
    table         = var.bigquery_table
  }

  provisioner "local-exec" {
    command = <<-EOT
      python3 ${path.module}/scripts/enable_logging.py \
        --project ${var.project_id} \
        --location ${var.region} \
        --model ${var.vertex_ai_model} \
        --sampling-rate ${var.logging_sampling_rate} \
        --bq-destination "bq://${var.project_id}.${var.bigquery_dataset}.${var.bigquery_table}"
    EOT
  }

  depends_on = [
    google_bigquery_dataset.vertex_ai_logs,
  ]
}

# --- Allow Scheduler to invoke the function ---

resource "google_cloud_run_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.vertex_ai_collector.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.collector.email}"
}
