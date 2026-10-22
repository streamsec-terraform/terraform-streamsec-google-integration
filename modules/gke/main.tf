locals {
  # log_filter.txt is copied from lightlytics/gcp-deploymentmanager
  # code/gke-logs/setup-realtime.sh (LOG_FILTER) @ 7e5cf3c; keep in sync.
  base_filter = trimspace(file("${path.module}/log_filter.txt"))

  project_ids      = [for p in var.projects : p.project_id]
  include_projects = distinct(var.include_projects)
  include_clusters = distinct(var.include_clusters)
  exclude_clusters = distinct(var.exclude_clusters)

  gke_projects = length(local.include_projects) == 0 ? var.projects : {
    for k, p in var.projects : k => p if contains(local.include_projects, p.project_id)
  }

  # Keyed by project id. The fallback lets the precondition report a project_for_resources
  # outside projects; the data sources skip it.
  deploy_projects = var.org_level_sink ? {
    (var.project_for_resources) = try(var.projects[var.project_for_resources], { project_id = var.project_for_resources, name = var.project_for_resources })
  } : local.gke_projects

  apis = [
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "logging.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
  ]

  project_apis = {
    for pair in setproduct(keys(local.deploy_projects), local.apis) :
    "${pair[0]}/${pair[1]}" => { project = local.deploy_projects[pair[0]].project_id, api = pair[1] }
  }

  filter_clauses = compact([
    var.org_level_sink && length(local.include_projects) > 0 ? "(${join(" OR ", [for p in local.include_projects : "resource.labels.project_id=\"${p}\""])})" : "",
    length(local.include_clusters) > 0 ? "(${join(" OR ", [for c in local.include_clusters : "resource.labels.cluster_name=\"${c}\""])})" : "",
    length(local.exclude_clusters) > 0 ? "-(${join(" OR ", [for c in local.exclude_clusters : "resource.labels.cluster_name=\"${c}\""])})" : "",
  ])

  sink_filter = join("\n", concat([local.base_filter], local.filter_clauses))

  # Integrated deploy projects only, so a bad project_for_resources gives only the precondition error.
  data_projects = { for k, p in local.deploy_projects : k => p if contains(local.project_ids, p.project_id) }

  sink_writer_identities = var.org_level_sink ? {
    for k in keys(local.deploy_projects) : k => google_logging_organization_sink.this[0].writer_identity
    } : {
    for k, s in google_logging_project_sink.this : k => s.writer_identity
  }
}

resource "terraform_data" "inputs" {
  lifecycle {
    precondition {
      condition     = !var.org_level_sink || (var.organization_id != null && var.organization_id != "")
      error_message = "organization_id is required when org_level_sink is true."
    }
    precondition {
      condition     = !var.org_level_sink || contains(local.project_ids, var.project_for_resources)
      error_message = "project_for_resources must be an integrated project (one of projects) when org_level_sink is true."
    }
    precondition {
      condition     = alltrue([for p in local.include_projects : contains(local.project_ids, p)])
      error_message = "include_projects must only contain integrated projects."
    }
    precondition {
      condition     = var.org_level_sink || length(local.gke_projects) > 0
      error_message = "Project mode needs at least one GKE project."
    }
    precondition {
      condition     = length(setintersection(local.include_clusters, local.exclude_clusters)) == 0
      error_message = "A cluster name must not be in both include_clusters and exclude_clusters."
    }
    precondition {
      condition     = alltrue([for c in concat(local.include_clusters, local.exclude_clusters) : can(regex("^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$", c))])
      error_message = "Cluster names must match ^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$."
    }
    precondition {
      condition     = length(local.sink_filter) <= 20000
      error_message = "The sink filter is longer than 20,000 characters. Use fewer names in include_clusters, exclude_clusters or include_projects (root: gke_include_clusters, gke_exclude_clusters, gke_include_projects)."
    }
  }
}

data "streamsec_host" "this" {}

data "google_project" "this" {
  for_each   = local.data_projects
  project_id = each.value.project_id
}

data "streamsec_gcp_project" "this" {
  for_each = local.data_projects
  # lookup, not try(): on Terraform 1.5 try() over a map with any unknown value is unknown,
  # which would defer (and replace) the token of every project, not only the new one.
  project_id = lookup(var.acked_project_ids, each.key, each.value.project_id)
}

resource "google_project_service" "this" {
  for_each           = local.project_apis
  project            = each.value.project
  service            = each.value.api
  disable_on_destroy = false
  depends_on         = [terraform_data.inputs]
}

# One wait for all projects; a project added later changes the trigger, so it waits again.
resource "time_sleep" "api_propagation" {
  create_duration = "30s"
  triggers = {
    apis = join(",", sort(keys(local.project_apis)))
  }
  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret" "this" {
  for_each  = local.deploy_projects
  project   = each.value.project_id
  secret_id = var.secret_name
  replication {
    auto {}
  }
  depends_on = [terraform_data.inputs, time_sleep.api_propagation]
}

resource "google_secret_manager_secret_version" "this" {
  for_each    = local.deploy_projects
  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = data.streamsec_gcp_project.this[each.key].account_token
}

resource "google_service_account" "this" {
  for_each     = local.deploy_projects
  project      = each.value.project_id
  account_id   = "streamsec-gke-audit"
  display_name = "Stream Security GKE audit logs"
  depends_on   = [terraform_data.inputs, time_sleep.api_propagation]
}

resource "google_secret_manager_secret_iam_member" "this" {
  for_each  = local.deploy_projects
  project   = each.value.project_id
  secret_id = google_secret_manager_secret.this[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this[each.key].email}"
}

resource "google_pubsub_topic" "this" {
  for_each   = local.deploy_projects
  project    = each.value.project_id
  name       = "streamsec-gke-audit-logs"
  depends_on = [terraform_data.inputs, time_sleep.api_propagation]
}

resource "google_logging_organization_sink" "this" {
  count            = var.org_level_sink ? 1 : 0
  name             = "streamsec-gke-audit-logs-pubsub"
  org_id           = var.organization_id
  destination      = "pubsub.googleapis.com/${google_pubsub_topic.this[var.project_for_resources].id}"
  filter           = local.sink_filter
  include_children = true
  depends_on       = [terraform_data.inputs]
}

resource "google_logging_project_sink" "this" {
  for_each               = var.org_level_sink ? {} : local.gke_projects
  project                = each.value.project_id
  name                   = "streamsec-gke-audit-logs-pubsub"
  destination            = "pubsub.googleapis.com/${google_pubsub_topic.this[each.key].id}"
  filter                 = local.sink_filter
  unique_writer_identity = true
  depends_on             = [terraform_data.inputs]
}

resource "google_pubsub_topic_iam_member" "sink_publisher" {
  for_each = local.deploy_projects
  project  = each.value.project_id
  topic    = google_pubsub_topic.this[each.key].name
  role     = "roles/pubsub.publisher"
  member   = local.sink_writer_identities[each.key]
}

resource "google_cloudfunctions2_function" "this" {
  for_each = local.deploy_projects
  project  = each.value.project_id
  name     = "stream-sec-gke-logs-pubsub"
  location = var.region

  build_config {
    runtime         = "nodejs22"
    entry_point     = "PubSubGKELogsCollection"
    service_account = var.build_service_account == null ? null : replace(var.build_service_account, "{project}", each.key)
    source {
      storage_source {
        bucket = var.source_bucket
        object = var.source_object
      }
    }
  }

  service_config {
    service_account_email = google_service_account.this[each.key].email
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    environment_variables = {
      API_URL     = data.streamsec_host.this.host
      SECRET_NAME = "projects/${each.value.project_id}/secrets/${var.secret_name}/versions/latest"
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.this[each.key].id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.this[each.key].email
  }

  depends_on = [terraform_data.inputs, time_sleep.api_propagation, google_secret_manager_secret_version.this, google_secret_manager_secret_iam_member.this]
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = local.deploy_projects
  project  = each.value.project_id
  location = var.region
  name     = google_cloudfunctions2_function.this[each.key].service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.this[each.key].email}"
}

resource "google_service_account_iam_member" "pubsub_token_creator" {
  for_each           = local.deploy_projects
  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.this[each.key].number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  # The Pub/Sub service agent appears once the API is on; wait for the API and the topic.
  depends_on = [time_sleep.api_propagation, google_pubsub_topic.this]
}
