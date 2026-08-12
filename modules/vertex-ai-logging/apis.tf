resource "google_project_service" "required_apis" {
  for_each = var.manage_apis ? toset([
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "run.googleapis.com",
    "bigquery.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    # Gen2 function builds push the container image to Artifact Registry.
    "artifactregistry.googleapis.com",
    # :setPublisherModelConfig (restapi_object.publisher_model_logging) and the Vertex AI
    # service agent that writes the logging tables.
    "aiplatform.googleapis.com",
  ]) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Enabling a service returns before the activation has fully propagated, so resources that
# consume a just-enabled API can still race it and fail with a service-disabled error on a
# fresh project. Consumers depend on this rather than on google_project_service directly.
resource "time_sleep" "api_propagation" {
  count = var.manage_apis ? 1 : 0

  depends_on      = [google_project_service.required_apis]
  create_duration = "30s"
}
