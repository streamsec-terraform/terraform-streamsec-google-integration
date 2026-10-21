mock_provider "google" {}

variables {
  hub_project_id = "scanner-hub-123"
  org_id         = "123456789012"
}

# Stream's console renders a gcloud command that creates this same role
# (lightlytics ms_accounts/account_handler.py, _gcp_scanner_access_command). An
# organization may use either, or both over time, so the role must be the
# command's exactly: another id would be a second role, and another permission
# set would flip back and forth each time one of them runs.
run "role_matches_the_console_command" {
  command = plan

  assert {
    condition     = google_organization_iam_custom_role.target.role_id == "streamsecVolumeScannerTarget"
    error_message = "The role id must be the console command's, streamsecVolumeScannerTarget."
  }

  assert {
    condition     = google_organization_iam_custom_role.target.org_id == "123456789012"
    error_message = "The role must be defined in the organization."
  }

  assert {
    condition     = google_organization_iam_custom_role.target.title == "Stream Security volume scanner: scanned projects"
    error_message = "The role title must be the console command's."
  }

  assert {
    condition     = google_organization_iam_custom_role.target.stage == "GA"
    error_message = "The role must be at stage GA, as the console command creates it."
  }

  # Read access plus a snapshot of each disk. Everything that creates or
  # deletes stays in the hub's own project role (modules/volume-scanner).
  assert {
    condition = toset(google_organization_iam_custom_role.target.permissions) == toset([
      "compute.instances.list",
      "compute.instances.get",
      "compute.disks.get",
      "compute.disks.createSnapshot",
      "resourcemanager.projects.get",
      "run.locations.list",
      "run.services.list",
      "run.revisions.get",
      "run.jobs.list",
      "cloudfunctions.functions.list",
      "cloudfunctions.functions.sourceCodeGet",
      "artifactregistry.repositories.downloadArtifacts",
    ])
    error_message = "The role must grant exactly the console command's 12 permissions."
  }
}
