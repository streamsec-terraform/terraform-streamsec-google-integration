# Region the (regional) shared secret lives in — same provider region the real-time-events
# module uses when it creates the regional secret, so the derived path matches.
data "google_client_config" "current" {}

locals {
  # Project that OWNS the token secret, which is not always the project this pipeline deploys
  # into: real-time-events creates the shared secret only in project_for_resources when
  # org_level_sink = true. A cross-project deployment must therefore be told where the secret
  # lives, or both the derived version path and the IAM grant below target a secret that does
  # not exist. Defaults to this project, which is the single-project case.
  secret_owner_project = var.secret_project != "" ? var.secret_project : var.project_id

  # Full secret VERSION resource name the function reads. Derived from the existing
  # secret_name / regional_secret inputs (matching the secret real-time-events creates),
  # unless an explicit secret_version_name override is provided. Read verbatim by the function.
  secret_version_name = var.secret_version_name != "" ? var.secret_version_name : (
    var.regional_secret
    ? "projects/${local.secret_owner_project}/locations/${data.google_client_config.current.region}/secrets/${var.secret_name}/versions/latest"
    : "projects/${local.secret_owner_project}/secrets/${var.secret_name}/versions/latest"
  )

  # Decompose the (externally-owned) secret the function reads so the secretAccessor grant can be
  # scoped to that ONE secret instead of the whole project. When secret_version_name is overridden,
  # parse the parts from the path; otherwise use the secret_name/regional_secret/region inputs.
  secret_overridden  = var.secret_version_name != ""
  secret_is_regional = local.secret_overridden ? can(regex("/locations/", var.secret_version_name)) : var.regional_secret
  secret_project     = local.secret_overridden ? regex("projects/([^/]+)/", var.secret_version_name)[0] : local.secret_owner_project
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

  # Google-managed Vertex AI service agent that writes the request-response logging tables.
  vertex_ai_service_agent = "service-${data.google_project.this.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"

  # See var.bigquery_grant_scope. Dataset scope is least privilege but requires
  # bigquery.datasets.update; project scope is the fallback when the deployer lacks it.
  grant_bq_at_dataset = var.bigquery_grant_scope == "dataset"
  grant_bq_at_project = var.bigquery_grant_scope == "project"

  # Resource-name prefix for the publisher models whose logging config we manage. The regional
  # host is set on the restapi provider (https://<region>-aiplatform.googleapis.com) by the caller.
  publisher_model_prefix = "projects/${var.project_id}/locations/${var.region}/publishers/google/models"

  logging_output_uri = "bq://${var.project_id}.${local.bigquery_dataset_id}.${var.bigquery_table}"

  # Body of SetPublisherModelConfigRequest. updateMask scopes the write to loggingConfig; without
  # it the API REPLACES the entire PublisherModelConfig, silently clearing sibling settings
  # (claudeFeatureConfig, inferenceEventLoggingConfig, dataSharingEnabledProvider) on a publisher
  # model that other teams in the project may also be configuring.
  publisher_logging_enable = {
    publisherModelConfig = {
      loggingConfig = {
        enabled      = true
        samplingRate = var.logging_sampling_rate
        bigqueryDestination = {
          outputUri = local.logging_output_uri
        }
        enableOtelLogging = true
      }
    }
    updateMask = "loggingConfig"
  }

  # Sent on destroy: there is no DELETE for this API, so tearing the module down turns logging off
  # instead of leaving it enabled against a dataset that is about to disappear.
  publisher_logging_disable = {
    publisherModelConfig = {
      loggingConfig = {
        enabled = false
      }
    }
    updateMask = "loggingConfig"
  }
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

# Read access to the logging data is granted at DATASET scope, not project scope: the collector
# forwards what it reads to an external endpoint, so a project-wide dataViewer would put every
# unrelated dataset in the blast radius of a compromise. See the dataset `access` blocks below
# (created dataset) and google_bigquery_dataset_iam_member.* (pre-existing dataset).
#
# jobUser has no dataset-scoped equivalent — running a query job is inherently a project-level
# permission — so it stays here. It confers no data access on its own.
resource "google_project_iam_member" "bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.api_propagation]
}

# Least-privilege: grant secretAccessor on the single external secret the function reads,
# not the whole project. Global vs regional secret selects the matching IAM resource.
resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  count     = var.manage_secret_iam && !local.secret_is_regional ? 1 : 0
  project   = local.secret_project
  secret_id = local.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.api_propagation]
}

resource "google_secret_manager_regional_secret_iam_member" "secret_accessor" {
  count     = var.manage_secret_iam && local.secret_is_regional ? 1 : 0
  project   = local.secret_project
  location  = local.secret_location
  secret_id = local.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.api_propagation]
}

# Vertex AI service agent — needs write access to create and populate the BigQuery logging
# tables. Also granted at dataset scope only (see local.vertex_ai_service_agent usage below);
# a project-wide dataEditor would let a managed service agent modify every dataset in the
# project, and would additionally make `terraform destroy` here revoke a binding other
# deployments in the same project may depend on.
data "google_project" "this" {
  project_id = var.project_id
}

# --- GCS Bucket (watermark state) ---

resource "google_storage_bucket" "state" {
  project                     = var.project_id
  name                        = local.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [time_sleep.api_propagation]

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

  # Dataset-scoped read for the collector, in place of a project-wide dataViewer.
  access {
    role          = "READER"
    user_by_email = google_service_account.collector.email
  }

  # Dataset-scoped write for the Vertex AI service agent, in place of a project-wide dataEditor.
  # WRITER is what lets it create the date-sharded tables and stream rows into them.
  #
  # Dynamic because adding this entry to an ALREADY-CREATED dataset is a datasets.update call.
  # A deployer holding only datasets.create can create the dataset with these blocks but cannot
  # later modify them, so bigquery_grant_scope = "project" omits the entry and grants at project
  # level instead, leaving the access list byte-identical to what such a deployer first created.
  dynamic "access" {
    for_each = local.grant_bq_at_dataset ? [1] : []
    content {
      role          = "WRITER"
      user_by_email = local.vertex_ai_service_agent
    }
  }

  depends_on = [time_sleep.api_propagation]
}

# --- Project-scoped BigQuery grants (bigquery_grant_scope = "project") ---
#
# Broader than the dataset-scoped default: dataViewer lets the collector read every dataset in
# the project, and dataEditor lets the Vertex AI service agent modify every dataset. Use only
# when the deployer cannot hold bigquery.datasets.update on the logging dataset. Note these are
# additive project bindings, so `terraform destroy` revokes them for anything else in the project
# that happens to rely on the same grant.
resource "google_project_iam_member" "bq_reader" {
  count = local.grant_bq_at_project ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "vertex_ai_bq_writer" {
  count = local.grant_bq_at_project ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${local.vertex_ai_service_agent}"

  depends_on = [time_sleep.api_propagation]
}

# When the dataset is NOT managed here, the authoritative `access` blocks above don't exist, so
# grant the same two dataset-scoped roles additively instead. google_bigquery_dataset_iam_member
# and a dataset resource's `access` blocks are mutually exclusive on the same dataset — mixing
# them makes each fight the other on every plan — hence the count gate.
resource "google_bigquery_dataset_iam_member" "collector_reader" {
  count = !var.create_bigquery_dataset && local.grant_bq_at_dataset ? 1 : 0

  project    = var.project_id
  dataset_id = local.bigquery_dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.api_propagation]
}

resource "google_bigquery_dataset_iam_member" "vertex_ai_writer" {
  count = !var.create_bigquery_dataset && local.grant_bq_at_dataset ? 1 : 0

  project    = var.project_id
  dataset_id = local.bigquery_dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${local.vertex_ai_service_agent}"

  depends_on = [time_sleep.api_propagation]
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

  depends_on = [time_sleep.api_propagation]

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
      LOOKBACK_MINUTES = tostring(var.lookback_minutes)
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
#
# There is no first-class provider resource for this. The Google provider's
# predict_request_response_logging_config lives on google_vertex_ai_endpoint, which covers only
# self-deployed endpoints -- serverless publisher models (gemini-*) are configured through
# aiplatform's :setPublisherModelConfig instead. A native resource is requested upstream in
# hashicorp/terraform-provider-google#24092 but is still unimplemented, so we drive the REST
# method declaratively via the restapi provider.
#
# One object per model. All models write to the same prefixed dataset/table; rows are
# distinguished by the model column, so the destination is shared.

resource "restapi_object" "publisher_model_logging" {
  for_each = var.enable_request_response_logging ? toset(var.vertex_ai_models) : toset([])

  # :setPublisherModelConfig returns a long-running Operation rather than the configured object,
  # so there is no server-assigned id to scrape from the create response. Pin the id to the model
  # name instead. `path` is only a fallback for verbs without an explicit path (all four have one
  # below), but the provider requires it.
  path      = "/v1beta1/${local.publisher_model_prefix}"
  object_id = each.value

  # This API is "set config", not REST CRUD: create, update and destroy are all POSTs to the same
  # :setPublisherModelConfig method, differing only in the body. There is no DELETE.
  create_path    = "/v1beta1/${local.publisher_model_prefix}/${each.value}:setPublisherModelConfig"
  update_path    = "/v1beta1/${local.publisher_model_prefix}/${each.value}:setPublisherModelConfig"
  destroy_path   = "/v1beta1/${local.publisher_model_prefix}/${each.value}:setPublisherModelConfig"
  update_method  = "POST"
  destroy_method = "POST"

  read_path = "/v1beta1/${local.publisher_model_prefix}/${each.value}:fetchPublisherModelConfig"

  # fetchPublisherModelConfig returns a bare PublisherModelConfig ({"loggingConfig":{...}}) while
  # the POST body wraps it ({"publisherModelConfig":{...},"updateMask":...}). The two shapes can
  # never compare equal, so reconciling the read response against `data` would produce a permanent
  # diff. Edits to `data` (sampling rate, destination) still trigger an update normally.
  ignore_all_server_changes = true

  data         = jsonencode(local.publisher_logging_enable)
  destroy_data = jsonencode(local.publisher_logging_disable)

  depends_on = [
    google_bigquery_dataset.vertex_ai_logs,
    google_bigquery_dataset_iam_member.vertex_ai_writer,
    google_project_iam_member.vertex_ai_bq_writer,
    time_sleep.api_propagation,
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
