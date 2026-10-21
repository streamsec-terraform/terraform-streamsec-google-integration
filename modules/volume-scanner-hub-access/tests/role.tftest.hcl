mock_provider "google" {}

variables {
  hub_project_ids = ["scanner-hub-123"]
  org_id          = "123456789012"
}

# Stream's console renders a gcloud command that creates this same role
# (lightlytics ms_accounts/account_handler.py, _gcp_scanner_access_command). An
# organization may use either, or both over time, so the role must be the
# command's exactly: another id would be a second role, and another permission
# set would flip back and forth each time one of them runs.
run "role_matches_the_console_command" {
  command = plan

  assert {
    condition     = google_organization_iam_custom_role.target[0].role_id == "streamsecVolumeScannerTarget"
    error_message = "The role id must be the console command's, streamsecVolumeScannerTarget."
  }

  assert {
    condition     = google_organization_iam_custom_role.target[0].org_id == "123456789012"
    error_message = "The role must be defined in the organization."
  }

  assert {
    condition     = google_organization_iam_custom_role.target[0].title == "Stream Security volume scanner: scanned projects"
    error_message = "The role title must be the console command's."
  }

  assert {
    condition     = google_organization_iam_custom_role.target[0].stage == "GA"
    error_message = "The role must be at stage GA, as the console command creates it."
  }

  # Read access plus a snapshot of each disk. Everything that creates or
  # deletes stays in the hub's own project role (modules/volume-scanner).
  assert {
    condition = toset(google_organization_iam_custom_role.target[0].permissions) == toset([
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

# A role the module creates is bound through the resource, so each binding
# waits for the role it names. Here, not in grant_on's tests: the role must be
# created in this run for the override to apply, and those runs share a state
# that already holds it.
# A binding's role is ForceNew, so it must not depend on who owns the role:
# switching create_role either way would otherwise replace every binding.
run "bindings_name_the_role_whoever_owns_it" {
  command = plan

  variables {
    grant_on = { folder_ids = ["111111111111"] }
  }

  assert {
    condition     = alltrue([for b in google_folder_iam_member.target : b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"])
    error_message = "With create_role = true the bindings must name the role literally."
  }
}

run "bindings_name_the_same_role_when_it_is_owned_elsewhere" {
  command = plan

  variables {
    grant_on    = { folder_ids = ["111111111111"] }
    create_role = false
  }

  assert {
    condition     = alltrue([for b in google_folder_iam_member.target : b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"])
    error_message = "With create_role = false the bindings must name the same role as with true."
  }
}
