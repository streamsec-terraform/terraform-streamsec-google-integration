resource "google_project_service" "required_apis" {
  for_each = var.manage_apis ? toset([
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "run.googleapis.com",
    "bigquery.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
