data "google_project" "this" {
  project_id = var.project_id
}

locals {
  project_number          = data.google_project.this.number
  gcs_service_agent_email = "service-${local.project_number}@gs-project-accounts.iam.gserviceaccount.com"
  secret_resource_path    = "projects/${var.project_id}/secrets/${var.secret_name}/versions/latest"
  bucket_suffix           = substr(sha256(var.project_id), 0, 8)
  logs_bucket_name        = "${var.bucket_name}-${local.bucket_suffix}"
  artifact_object_name    = "gcp-gke-logs-collection.zip"
}

#
# Enable required APIs (minimum set for this workflow)
#
resource "google_project_service" "apis" {
  for_each = toset([
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
    "pubsub.googleapis.com",
    "iam.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

#
# (2) Logs bucket - destination for org sink
#
resource "google_storage_bucket" "logs" {
  name                        = local.logs_bucket_name
  project                     = var.project_id
  location                    = var.bucket_location
  uniform_bucket_level_access = true
  force_destroy               = false

  retention_policy {
    retention_period = 2592000 # 30 days (30 * 24 * 60 * 60)
    is_locked        = false
  }

  depends_on = [google_project_service.apis]
}

#
# (3) Org-level logging sink -> writes into the bucket
# Destination format: storage.googleapis.com/<BUCKET_NAME>
#
resource "google_logging_organization_sink" "org_sink" {
  name        = var.log_sink_name
  org_id      = var.org_id
  destination = "storage.googleapis.com/${google_storage_bucket.logs.name}"

  # Include children so it can capture projects/folders under the org.
  # If you ONLY want org-level logs excluding children, set to false.
  include_children = true

  filter = <<-EOT
resource.type="k8s_cluster"
-protoPayload.authenticationInfo.principalEmail=~"system:"
-protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com"
-protoPayload.methodName="io.k8s.coordination.v1.leases.update"
-protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.update"
-(protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update")
protoPayload.methodName=~""
EOT

  depends_on = [google_project_service.apis]
}

#
# Allow the sink's writer identity to write objects into the bucket
# (writer_identity is created by Logging on sink creation)
#
resource "google_storage_bucket_iam_member" "sink_writer_object_creator" {
  bucket = google_storage_bucket.logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.org_sink.writer_identity
}

#
# (1) Grant Cloud Storage service agent Pub/Sub Publisher (needed for Gen1 bucket triggers)
#
resource "google_project_iam_member" "gcs_agent_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.gcs_service_agent_email}"

  depends_on = [google_project_service.apis]
}

#
# (5) Secret Manager secret + version for StreamSec token
#
resource "google_secret_manager_secret" "token" {
  project   = var.project_id
  secret_id = var.secret_name

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "token_v1" {
  secret      = google_secret_manager_secret.token.id
  secret_data = var.streamsec_token
}

#
# (4) Function service account
#
resource "google_service_account" "function_sa" {
  project      = var.project_id
  account_id   = "streamsec-gke-logs-fn"
  display_name = "StreamSec GKE Logs Collection Function"
}

# Grant secret access to function SA
resource "google_secret_manager_secret_iam_member" "fn_sa_secret_accessor" {
  secret_id = google_secret_manager_secret.token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
}

#
# (6) Cloud Function (Gen1) triggered by GCS object finalize
# Source zip is read directly from the public StreamSec artifacts bucket
#
resource "google_cloudfunctions_function" "collector" {
  name        = var.function_name
  project     = var.project_id
  region      = var.region
  runtime     = var.function_runtime
  entry_point = "StorageGKELogsCollection"

  service_account_email = google_service_account.function_sa.email

  # Source zip directly from public artifacts bucket
  source_archive_bucket = var.source_artifact_bucket
  source_archive_object = local.artifact_object_name

  # Trigger on logs bucket
  event_trigger {
    event_type = "google.storage.object.finalize"
    resource   = google_storage_bucket.logs.name
  }

  environment_variables = {
    API_URL     = var.api_url
    SECRET_NAME = local.secret_resource_path
  }

  depends_on = [
    google_project_service.apis,
    google_storage_bucket_iam_member.sink_writer_object_creator,
    google_project_iam_member.gcs_agent_pubsub_publisher,
    google_secret_manager_secret_iam_member.fn_sa_secret_accessor
  ]
}
