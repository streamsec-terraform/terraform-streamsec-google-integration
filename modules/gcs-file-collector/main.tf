data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # One collector per endpoint and bucket, so a project can run several side by side.
  # scripts/deploy-gcs-file-collector.sh derives the same names.
  endpoint_slug   = trim(substr(replace(var.api_url_suffix, "/", "-"), 0, 12), "-")
  resource_suffix = "${local.endpoint_slug}-${substr(sha256("${var.api_url_suffix}|${var.bucket_name}"), 0, 6)}"

  function_name      = "streamsec-${local.resource_suffix}"
  service_account_id = "ss-col-${local.resource_suffix}"
  build_account_id   = "ss-bld-${local.resource_suffix}"
  build_repository   = "streamsec-builds-${local.resource_suffix}"
  source_bucket_name = "streamsec-src-${data.google_project.this.number}-${local.resource_suffix}"
  token_secret       = "streamsec-collector-token-${local.resource_suffix}"
  deployer_role_id   = "streamsecCollectorDeployer_${replace(local.resource_suffix, "-", "_")}"

  # A Cloud Storage trigger must be in the bucket's location: a region, a dual-region such as
  # nam4, or a multi-region such as us.
  trigger_region = lower(data.google_storage_bucket.logs.location)

  labels = merge({
    managed-by = "terraform"
    component  = "streamsec-gcs-file-collector"
    collector  = local.resource_suffix
  }, var.labels)
}

data "google_storage_bucket" "logs" {
  name = var.bucket_name

  depends_on = [time_sleep.api_propagation]
}

resource "terraform_data" "bucket_contract" {
  input = data.google_storage_bucket.logs.project_number

  lifecycle {
    precondition {
      condition     = tostring(data.google_storage_bucket.logs.project_number) == tostring(data.google_project.this.number)
      error_message = "bucket_name must be a bucket in project_id: Eventarc delivers Cloud Storage events only to triggers in the bucket's project."
    }
  }
}

# --- Identities ---

resource "google_service_account" "collector" {
  project      = var.project_id
  account_id   = local.service_account_id
  display_name = "Stream Security file collector"
  description  = "Reads files written to gs://${var.bucket_name} and sends them to Stream Security."
}

resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = local.build_account_id
  display_name = "Stream Security file collector builder"
  description  = "Builds the file collector image without relying on a default service account."
}

# The runner Infrastructure Manager uses has Editor plus project IAM administration, but not
# resource-level setIamPolicy. Bootstrap only the policy permissions this module needs.
resource "google_project_iam_custom_role" "deployer" {
  count = var.deployment_service_account_email == "" ? 0 : 1

  project     = var.project_id
  role_id     = local.deployer_role_id
  title       = "Stream Security Collector Deployer ${local.resource_suffix}"
  description = "Manages IAM policies on the collector's buckets, build repository, Cloud Run service and secret."
  permissions = [
    "artifactregistry.repositories.getIamPolicy",
    "artifactregistry.repositories.setIamPolicy",
    "run.services.getIamPolicy",
    "run.services.setIamPolicy",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
  ]
}

resource "google_project_iam_member" "deployer" {
  count = var.deployment_service_account_email == "" ? 0 : 1

  project = var.project_id
  role    = google_project_iam_custom_role.deployer[0].id
  member  = "serviceAccount:${var.deployment_service_account_email}"
}

resource "time_sleep" "deployer_iam_propagation" {
  count = var.deployment_service_account_email == "" ? 0 : 1

  depends_on      = [google_project_iam_member.deployer]
  create_duration = "30s"
}

# --- Delivery: Cloud Storage -> Eventarc -> the function ---

# Cloud Storage publishes the bucket's events to the Pub/Sub topic Eventarc creates for the
# trigger, as the project's Cloud Storage service agent.
data "google_storage_project_service_account" "this" {
  project = var.project_id

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "storage_agent_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.this.email_address}"
}

resource "google_project_iam_member" "collector_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.collector.email}"
}

resource "google_storage_bucket_iam_member" "collector_reader" {
  bucket = var.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [
    terraform_data.bucket_contract,
    time_sleep.deployer_iam_propagation,
  ]
}

resource "google_secret_manager_secret" "collection_token" {
  project   = var.project_id
  secret_id = local.token_secret
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_secret_manager_secret_version" "collection_token" {
  secret      = google_secret_manager_secret.collection_token.id
  secret_data = var.stream_collection_token
}

resource "google_secret_manager_secret_iam_member" "collection_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.collection_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.deployer_iam_propagation]
}

# --- Build ---

resource "google_project_iam_member" "build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

resource "google_artifact_registry_repository" "build" {
  project       = var.project_id
  location      = var.region
  repository_id = local.build_repository
  description   = "Build images for the Stream Security file collector."
  format        = "DOCKER"
  labels        = local.labels

  depends_on = [time_sleep.api_propagation]
}

resource "google_artifact_registry_repository_iam_member" "build_artifact_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.build.location
  repository = google_artifact_registry_repository.build.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"

  depends_on = [time_sleep.deployer_iam_propagation]
}

resource "google_project_iam_member" "build_storage_object_user" {
  project = var.project_id
  role    = "roles/storage.objectUser"
  member  = "serviceAccount:${google_service_account.build.email}"

  condition {
    title       = "CollectorFunctionBuildObjects"
    description = "Restrict buildpack object access to Google-managed function build buckets."
    expression  = "resource.type == 'storage.googleapis.com/Object' && (resource.name.startsWith('projects/_/buckets/gcf-v2-sources-${data.google_project.this.number}-') || resource.name.startsWith('projects/_/buckets/gcf-v2-uploads-${data.google_project.this.number}-') || resource.name.startsWith('projects/_/buckets/run-sources-${var.project_id}-'))"
  }
}

resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = local.source_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = local.labels

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 7
    }
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_storage_bucket_iam_member" "build_source_reader" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.build.email}"

  depends_on = [time_sleep.deployer_iam_propagation]
}

data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "${path.module}/function_source"
  output_path = "${path.module}/.build/function_source.zip"
  excludes    = ["__pycache__"]
}

# Named by content, so that a new release of the code redeploys the function.
resource "google_storage_bucket_object" "function_source" {
  name   = "function-source-${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.function_source.output_path
}

resource "time_sleep" "iam_propagation" {
  depends_on = [
    google_artifact_registry_repository_iam_member.build_artifact_writer,
    google_project_iam_member.build_log_writer,
    google_project_iam_member.build_storage_object_user,
    google_storage_bucket_iam_member.build_source_reader,
    google_project_iam_member.storage_agent_publisher,
    google_project_iam_member.collector_event_receiver,
    google_storage_bucket_iam_member.collector_reader,
    google_secret_manager_secret_iam_member.collection_token,
  ]

  # IAM allow-policy changes typically take two minutes to propagate. The build fails on a
  # grant that is not effective yet, and Eventarc refuses a Cloud Storage trigger until the
  # service agent can publish; the Cloud Functions provider retries neither.
  create_duration = "2m"
}

resource "google_cloudfunctions2_function" "collector" {
  project     = var.project_id
  name        = local.function_name
  location    = var.region
  description = "Sends files written to gs://${var.bucket_name} to Stream Security (${var.api_url_suffix})."
  labels      = local.labels

  build_config {
    runtime           = "python312"
    entry_point       = "collect"
    service_account   = google_service_account.build.id
    docker_repository = google_artifact_registry_repository.build.id

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    available_memory      = "512M"
    timeout_seconds       = var.function_timeout_seconds
    min_instance_count    = 0
    max_instance_count    = var.max_instance_count
    service_account_email = google_service_account.collector.email
    # Requests still need run.invoker, which only the collector's own identity has.
    ingress_settings = "ALLOW_ALL"

    environment_variables = {
      API_URL        = trimsuffix(var.stream_api_url, "/")
      API_URL_SUFFIX = var.api_url_suffix
    }

    secret_environment_variables {
      key        = "API_TOKEN"
      project_id = var.project_id
      secret     = google_secret_manager_secret.collection_token.secret_id
      version    = google_secret_manager_secret_version.collection_token.version
    }
  }

  event_trigger {
    trigger_region        = local.trigger_region
    event_type            = "google.cloud.storage.object.v1.finalized"
    service_account_email = google_service_account.collector.email
    # A delivery the function raises on (Stream unreachable or 5xx) is retried for up to 24h.
    retry_policy = "RETRY_POLICY_RETRY"

    event_filters {
      attribute = "bucket"
      value     = var.bucket_name
    }
  }

  depends_on = [time_sleep.iam_propagation]
}

# Eventarc delivers as the collector's identity. Until this binding is effective deliveries
# fail with 403 and are retried.
resource "google_cloud_run_v2_service_iam_member" "trigger_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.collector.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.deployer_iam_propagation]
}
