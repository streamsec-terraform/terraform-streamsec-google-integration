# Region the (regional) shared secret lives in — same provider region the real-time-events
# module uses when it creates the regional secret, so the derived path matches.
data "google_client_config" "current" {}

locals {
  # Full secret VERSION resource name the function reads. Derived from the existing
  # secret_name / regional_secret inputs (matching the secret real-time-events creates),
  # unless an explicit secret_version_name override is provided. Read verbatim by the function.
  secret_version_name = var.secret_version_name != "" ? var.secret_version_name : (
    var.regional_secret
    ? "projects/${var.project_id}/locations/${data.google_client_config.current.region}/secrets/${var.secret_name}/versions/latest"
    : "projects/${var.project_id}/secrets/${var.secret_name}/versions/latest"
  )

  # Decompose the (externally-owned) secret the function reads so the secretAccessor grant can be
  # scoped to that ONE secret instead of the whole project. When secret_version_name is overridden,
  # parse the parts from the path; otherwise use the secret_name/regional_secret/region inputs.
  secret_overridden  = var.secret_version_name != ""
  secret_is_regional = local.secret_overridden ? can(regex("/locations/", var.secret_version_name)) : var.regional_secret
  secret_project     = local.secret_overridden ? regex("projects/([^/]+)/", var.secret_version_name)[0] : var.project_id
  secret_id          = local.secret_overridden ? regex("secrets/([^/]+)", var.secret_version_name)[0] : var.secret_name
  secret_location = local.secret_is_regional ? (
    local.secret_overridden ? regex("locations/([^/]+)", var.secret_version_name)[0] : data.google_client_config.current.region
  ) : null

  function_name = "${var.name_prefix}-vertex-ai-collector"
  # SA account_id is capped at 30 chars; use a short base. Length validated via precondition below.
  sa_name = "${var.name_prefix}-vtx-col"
  # project_id keeps the bucket name globally unique.
  bucket_name = lower("${var.name_prefix}-vtx-collector-state-${var.project_id}")

  # Prefix the dataset with name_prefix like every other resource. BigQuery dataset IDs allow only
  # letters/numbers/underscores (no hyphens), so any hyphen in name_prefix is sanitized to '_'
  # (default -> streamsec_vertex_ai_logs).
  bigquery_dataset_id = "${replace(var.name_prefix, "-", "_")}_${var.bigquery_dataset}"
}

# --- Service Account ---

resource "google_service_account" "collector" {
  project      = var.project_id
  account_id   = local.sa_name
  display_name = "Stream Security Vertex AI Log Collector"
  # Explicit so terraform re-enables the SA if it gets disabled out-of-band. A disabled
  # runtime/OIDC SA breaks token minting -> function 500s and scheduler can't invoke.
  disabled = false

  lifecycle {
    precondition {
      condition     = length(local.sa_name) <= 30
      error_message = "Derived service account account_id '${local.sa_name}' exceeds 30 chars. Shorten name_prefix."
    }
  }
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

# Least-privilege: grant secretAccessor on the single external secret the function reads,
# not the whole project. Global vs regional secret selects the matching IAM resource.
resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  count     = var.manage_secret_iam && !local.secret_is_regional ? 1 : 0
  project   = local.secret_project
  secret_id = local.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"
}

resource "google_secret_manager_regional_secret_iam_member" "secret_accessor" {
  count     = var.manage_secret_iam && local.secret_is_regional ? 1 : 0
  project   = local.secret_project
  location  = local.secret_location
  secret_id = local.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"
}

# Vertex AI service agent needs write access to create and populate BigQuery logging tables
data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_iam_member" "vertex_ai_bq_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
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

  project                     = var.project_id
  dataset_id                  = local.bigquery_dataset_id
  location                    = var.bigquery_location
  default_table_expiration_ms = var.bigquery_log_retention_days * 86400000
  delete_contents_on_destroy  = true

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
    # ALLOW_ALL so the (external) Cloud Scheduler can invoke; access is still gated by
    # OIDC auth + the run.invoker binding below. ALLOW_INTERNAL_ONLY 404s the scheduler.
    ingress_settings = "ALLOW_ALL"

    environment_variables = {
      GCP_PROJECT_ID   = var.project_id
      BIGQUERY_DATASET = local.bigquery_dataset_id
      BIGQUERY_TABLE   = var.bigquery_table
      API_URL          = var.api_url
      STATE_BUCKET     = google_storage_bucket.state.name
      BATCH_SIZE       = tostring(var.batch_size)
      SECRET_NAME      = local.secret_version_name
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

# --- Enable request-response logging on publisher model(s) ---
# One null_resource per model. All models log to the same env-prefixed BigQuery dataset/table
# (rows are distinguished by the model column), so the destination is shared.

resource "null_resource" "enable_logging" {
  for_each = var.enable_request_response_logging ? toset(var.vertex_ai_models) : toset([])

  triggers = {
    model         = each.value
    sampling_rate = var.logging_sampling_rate
    dataset       = local.bigquery_dataset_id
    table         = var.bigquery_table
  }

  # Single-line command so it runs under both POSIX sh and Windows cmd.exe (Terraform's default
  # local-exec interpreter on Windows). `python3` must be on PATH.
  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/enable_logging.py --project ${var.project_id} --location ${var.region} --model ${each.value} --sampling-rate ${var.logging_sampling_rate} --bq-destination \"bq://${var.project_id}.${local.bigquery_dataset_id}.${var.bigquery_table}\""
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
