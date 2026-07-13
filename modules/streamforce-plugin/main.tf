################################################################################
# StreamForce custom plugin — deploys the plugin as a PRIVATE (IAM-gated) Gen2
# Cloud Function (Cloud Run) in the customer's project, grants the Stream
# Security integration service account run.invoker, and acknowledges the URL.
#
# The plugin package is hosted by Stream Security (artifact_url); Cloud Functions
# Gen2 can only source from GCS, so the module stages the zip into a bucket in
# this project. Env values are passed straight into the function and never pass
# through the Stream platform.
################################################################################

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  short_id     = substr(var.plugin_id, 0, 8)
  service_name = "sfplugin-${local.short_id}"
  has_env      = length(var.plugin_env) > 0
  # The function's runtime identity (Gen2 defaults to the Compute Engine SA).
  runtime_sa = "${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "random_id" "bucket" {
  byte_length = 4
}

# The plugin env, stored in Secret Manager (not a plain env var) so the values
# live in the customer's secret store. The value comes from var.plugin_env — it
# never passes through the Stream platform.
resource "google_secret_manager_secret" "env" {
  count     = local.has_env ? 1 : 0
  project   = var.project_id
  secret_id = "${local.service_name}-env"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "env" {
  count       = local.has_env ? 1 : 0
  secret      = google_secret_manager_secret.env[0].id
  secret_data = jsonencode(var.plugin_env)
}

# Let the function's runtime SA read the secret (granted up-front to avoid a
# deploy-time access check failing).
resource "google_secret_manager_secret_iam_member" "env" {
  count     = local.has_env ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.env[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.runtime_sa}"
}

# Bucket that holds the staged plugin source for Cloud Build.
resource "google_storage_bucket" "src" {
  name                        = "${local.service_name}-src-${random_id.bucket.hex}"
  project                     = var.project_id
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
  labels                      = var.labels
}

# Fetch the Stream-hosted plugin package and stage it locally (Gen2 source must
# live in GCS, and can't reference an arbitrary URL).
resource "null_resource" "fetch_artifact" {
  triggers = { artifact_url = var.artifact_url }

  provisioner "local-exec" {
    command = "curl -fsSL '${var.artifact_url}' -o '${path.module}/${local.service_name}.zip'"
  }
}

resource "google_storage_bucket_object" "src" {
  name       = "${local.service_name}-${random_id.bucket.hex}.zip"
  bucket     = google_storage_bucket.src.name
  source     = "${path.module}/${local.service_name}.zip"
  depends_on = [null_resource.fetch_artifact]
}

# The plugin function (Gen2 = Cloud Run under the hood). Internet-reachable but
# IAM-gated — only the Stream integration SA is granted run.invoker below.
resource "google_cloudfunctions2_function" "this" {
  name     = local.service_name
  project  = var.project_id
  location = var.region
  labels   = var.labels

  build_config {
    runtime     = var.runtime
    entry_point = "plugin"
    source {
      storage_source {
        bucket = google_storage_bucket.src.name
        object = google_storage_bucket_object.src.name
      }
    }
  }

  service_config {
    available_memory = var.available_memory
    timeout_seconds  = var.timeout_seconds
    ingress_settings = "ALLOW_ALL"
    environment_variables = {
      PLUGIN_ID    = var.plugin_id
      PLUGIN_TOKEN = var.plugin_token
      PLATFORM_URL = var.platform_url
    }

    # The customer env blob is delivered from Secret Manager (not a plain env
    # var) and expanded into process.env by the plugin at start.
    dynamic "secret_environment_variables" {
      for_each = local.has_env ? [1] : []
      content {
        key        = "PLUGIN_ENV_JSON"
        project_id = var.project_id
        secret     = google_secret_manager_secret.env[0].secret_id
        version    = "latest"
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.env]
}

# Grant the Stream Security integration service account permission to invoke the
# function. Stream signs its tool calls with an OIDC id_token for this SA.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.this.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.invoker_sa_email}"
}

# Acknowledge the deployed function URL back to Stream Security (authenticated by
# the per-plugin token). The plugin flips to Active once its tools are reachable.
resource "null_resource" "acknowledge" {
  triggers = {
    url = google_cloudfunctions2_function.this.url
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -fsS -X POST '${var.platform_url}/api/accounts/streamforce-plugins/acknowledge' \
        -H 'Authorization: Bearer ${var.plugin_token}' \
        -H 'Content-Type: application/json' \
        -d '{"function_url": "${google_cloudfunctions2_function.this.url}"}'
    EOT
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker]
}
