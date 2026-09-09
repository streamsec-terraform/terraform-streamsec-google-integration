data "google_project" "this" {
  project_id = var.project_id
}

locals {
  function_name      = "streamsec-palo-waf"
  service_account_id = "streamsec-palo-waf"
  build_account_id   = "streamsec-palo-waf-build"
  scheduler_name     = "streamsec-palo-waf-poll"
  connector_name     = "streamsec-palo-waf"
  source_bucket_name = "streamsec-palo-waf-src-${data.google_project.this.number}"
  integration_secret = "streamsec-palo-waf-token"
  deployment_id      = "streamsec-palo-alto-waf"
  firewall_versions  = toset(compact([for name in split(",", var.firewall_secret_names) : trimspace(name)]))
  firewall_secret_groups = {
    for version_name in local.firewall_versions :
    "${split("/", version_name)[1]}/${split("/", version_name)[3]}" => {
      project   = split("/", version_name)[1]
      secret_id = split("/", version_name)[3]
    }...
  }

  network_name    = element(reverse(split("/", var.vpc_network)), 0)
  network_project = can(regex("projects/([^/]+)", var.vpc_network)) ? regex("projects/([^/]+)", var.vpc_network)[0] : var.project_id
  subnet_name     = element(reverse(split("/", var.subnet)), 0)
  subnet_project  = can(regex("projects/([^/]+)", var.subnet)) ? regex("projects/([^/]+)", var.subnet)[0] : local.network_project
  subnet_region   = can(regex("regions/([^/]+)", var.subnet)) ? regex("regions/([^/]+)", var.subnet)[0] : var.region

  labels = merge({
    managed-by = "terraform"
    component  = "streamsec-palo-waf"
  }, var.labels)
}

resource "terraform_data" "network_scope_contract" {
  input = {
    network_project = local.network_project
    subnet_project  = local.subnet_project
    subnet_region   = local.subnet_region
  }

  lifecycle {
    precondition {
      condition     = local.network_project == var.project_id && local.subnet_project == var.project_id
      error_message = "vpc_network and subnet must belong to project_id. Shared VPC service projects require a dedicated host-project connector subnet and are not supported by this deployment contract."
    }

    precondition {
      condition     = local.subnet_region == var.region
      error_message = "subnet must be in region because Serverless VPC Access connectors are regional."
    }
  }
}

data "google_compute_network" "selected" {
  project = local.network_project
  name    = local.network_name

  depends_on = [
    terraform_data.network_scope_contract,
    time_sleep.api_propagation,
  ]
}

data "google_compute_subnetwork" "selected" {
  project = local.subnet_project
  region  = local.subnet_region
  name    = local.subnet_name

  depends_on = [
    terraform_data.network_scope_contract,
    time_sleep.api_propagation,
  ]
}

resource "terraform_data" "network_contract" {
  input = {
    network = data.google_compute_network.selected.self_link
    subnet  = data.google_compute_subnetwork.selected.self_link
  }

  lifecycle {
    precondition {
      condition     = data.google_compute_subnetwork.selected.network == data.google_compute_network.selected.self_link
      error_message = "subnet must belong to vpc_network so the function can route to the selected firewall."
    }

  }
}

resource "terraform_data" "secret_contract" {
  input = local.firewall_versions

  lifecycle {
    precondition {
      condition = alltrue([
        for version_name in local.firewall_versions :
        contains([var.project_id, tostring(data.google_project.this.number)], split("/", version_name)[1])
      ])
      error_message = "firewall_secret_names must reference secrets in project_id. The #22440 Infrastructure Manager runner has no IAM authority in other projects."
    }
  }
}

resource "google_service_account" "collector" {
  project      = var.project_id
  account_id   = local.service_account_id
  display_name = "Stream Security Palo Alto collector"
  description  = "Polls private NGFW management APIs and sends configuration to Stream Security."
}

resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = local.build_account_id
  display_name = "Stream Security Palo Alto function builder"
  description  = "Builds the Palo Alto collector image without relying on a default service account."
}

resource "google_project_iam_member" "build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "build_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.build.email}"

  condition {
    title       = "PaloWafFunctionRepositories"
    description = "Restrict the builder to Google-managed Cloud Functions repositories."
    expression  = "resource.name.endsWith('/repositories/gcf-artifacts') || resource.name.endsWith('/repositories/cloud-run-source-deploy')"
  }
}

resource "google_project_iam_member" "build_source_reader" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.build.email}"

  condition {
    title       = "PaloWafFunctionSources"
    description = "Restrict the builder to this module's source and Google-managed function source buckets."
    expression  = "resource.type == 'storage.googleapis.com/Object' && (resource.name.startsWith('projects/_/buckets/${local.source_bucket_name}/') || resource.name.startsWith('projects/_/buckets/gcf-v2-sources-${data.google_project.this.number}-') || resource.name.startsWith('projects/_/buckets/gcf-v2-uploads-${data.google_project.this.number}-') || resource.name.startsWith('projects/_/buckets/run-sources-${var.project_id}-'))"
  }
}

resource "time_sleep" "build_iam_propagation" {
  depends_on = [
    google_project_iam_member.build_artifact_writer,
    google_project_iam_member.build_log_writer,
    google_project_iam_member.build_source_reader,
  ]

  # IAM allow-policy changes typically take two minutes to propagate. Waiting
  # that full window avoids first-deployment builds starting before these grants
  # are effective; the Cloud Functions provider does not retry a failed build.
  create_duration = "2m"
}

# The #22440 runner has Editor (including serviceAccounts.actAs) plus project
# IAM administration, but not resource-level Cloud Run or Secret Manager
# setIamPolicy. Bootstrap only the four policy permissions this module needs.
resource "google_project_iam_custom_role" "deployer" {
  count = var.deployment_service_account_email == "" ? 0 : 1

  project     = var.project_id
  role_id     = "streamsecPaloWafDeployer"
  title       = "Stream Security Palo WAF Deployer"
  description = "Manages IAM policies on the Palo WAF Cloud Run service and secrets."
  permissions = [
    "run.services.getIamPolicy",
    "run.services.setIamPolicy",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
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

resource "google_secret_manager_secret" "integration_token" {
  project   = var.project_id
  secret_id = local.integration_secret
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_secret_manager_secret_version" "integration_token" {
  secret      = google_secret_manager_secret.integration_token.id
  secret_data = var.stream_integration_token
}

resource "google_secret_manager_secret_iam_member" "integration_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.integration_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.deployer_iam_propagation]
}

resource "google_secret_manager_secret_iam_member" "firewall_credentials" {
  for_each = local.firewall_secret_groups

  project   = each.value[0].project
  secret_id = each.value[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [
    terraform_data.secret_contract,
    time_sleep.api_propagation,
    time_sleep.deployer_iam_propagation,
  ]
}

resource "google_vpc_access_connector" "collector" {
  project       = var.project_id
  name          = local.connector_name
  region        = var.region
  network       = data.google_compute_network.selected.name
  ip_cidr_range = var.connector_cidr
  min_instances = 2
  max_instances = 3

  depends_on = [
    terraform_data.network_contract,
    time_sleep.api_propagation,
  ]
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

data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "${path.module}/function_source"
  output_path = "${path.module}/.build/function_source.zip"
}

resource "google_storage_bucket_object" "function_source" {
  name   = "function-source-${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.function_source.output_path
}

resource "google_cloudfunctions2_function" "collector" {
  project  = var.project_id
  name     = local.function_name
  location = var.region
  labels   = local.labels

  build_config {
    runtime         = "python312"
    entry_point     = "poll"
    service_account = google_service_account.build.id

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
    max_instance_count    = 1
    service_account_email = google_service_account.collector.email
    ingress_settings      = "ALLOW_ALL"

    environment_variables = {
      API_URL = trimsuffix(var.stream_api_url, "/")
    }

    secret_environment_variables {
      key        = "API_TOKEN"
      project_id = var.project_id
      secret     = google_secret_manager_secret.integration_token.secret_id
      version    = google_secret_manager_secret_version.integration_token.version
    }

    vpc_connector                 = google_vpc_access_connector.collector.id
    vpc_connector_egress_settings = "PRIVATE_RANGES_ONLY"
  }

  depends_on = [
    google_secret_manager_secret_iam_member.firewall_credentials,
    google_secret_manager_secret_iam_member.integration_token,
    time_sleep.build_iam_propagation,
    time_sleep.api_propagation,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.collector.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.collector.email}"

  depends_on = [time_sleep.deployer_iam_propagation]
}

resource "google_cloud_scheduler_job" "poll" {
  project          = var.project_id
  region           = var.region
  name             = local.scheduler_name
  schedule         = var.poll_schedule
  time_zone        = "Etc/UTC"
  attempt_deadline = "${var.function_timeout_seconds + 30}s"

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.collector.url

    oidc_token {
      service_account_email = google_service_account.collector.email
      audience              = google_cloudfunctions2_function.collector.url
    }
  }

  retry_config {
    retry_count          = 1
    min_backoff_duration = "10s"
    max_backoff_duration = "60s"
  }

  depends_on = [google_cloud_run_v2_service_iam_member.scheduler_invoker]
}
