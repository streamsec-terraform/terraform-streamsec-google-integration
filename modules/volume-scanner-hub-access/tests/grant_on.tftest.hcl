# The role's name is computed, so these runs apply against the mock, which
# sets it. Applying rather than overriding during plan keeps the tests valid on
# Terraform 1.7, the version in the repo's pre-commit hook image.
mock_provider "google" {
  mock_resource "google_organization_iam_custom_role" {
    defaults = {
      id   = "organizations/123456789012/roles/streamsecVolumeScannerTarget"
      name = "organizations/123456789012/roles/streamsecVolumeScannerTarget"
    }
  }
}

variables {
  hub_project_id = "scanner-hub-123"
  org_id         = "123456789012"
}

# As the console's command without folders: every project of the
# organization, including ones created later.
run "organization_by_default" {
  command = apply

  assert {
    condition = (
      length(google_organization_iam_member.target) == 1
      && length(google_folder_iam_member.target) == 0
      && length(google_project_iam_member.target) == 0
    )
    error_message = "By default the role must be granted on the organization alone."
  }

  assert {
    condition = (
      google_organization_iam_member.target[0].org_id == "123456789012"
      && google_organization_iam_member.target[0].role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
      && google_organization_iam_member.target[0].member == "serviceAccount:streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"
    )
    error_message = "The organization binding must grant the module's role to the hub's scanner service account."
  }

  assert {
    condition     = output.granted_on.scope == "organization" && toset(output.granted_on.ids) == toset(["123456789012"])
    error_message = "granted_on must name the organization."
  }

  assert {
    condition     = output.scanner_service_account_email == "streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"
    error_message = "The service account must be the one modules/volume-scanner creates in the hub."
  }

  assert {
    condition = (
      output.role_id == "streamsecVolumeScannerTarget"
      && output.role_name == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
    )
    error_message = "The outputs must name the role."
  }
}

# A null grant_on is the default, not "nowhere".
run "null_means_the_organization" {
  command = apply

  variables {
    grant_on = null
  }

  assert {
    condition     = length(google_organization_iam_member.target) == 1
    error_message = "A null grant_on must grant on the organization, as the default does."
  }
}

run "folders" {
  command = apply

  variables {
    grant_on = { folder_ids = ["111111111111", "222222222222"] }
  }

  assert {
    condition = (
      length(google_organization_iam_member.target) == 0
      && length(google_project_iam_member.target) == 0
      && toset(keys(google_folder_iam_member.target)) == toset(["111111111111", "222222222222"])
    )
    error_message = "Granting on folders must bind each folder, and nothing else."
  }

  assert {
    condition = alltrue([for id, b in google_folder_iam_member.target :
      b.folder == "folders/${id}"
      && b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
      && b.member == "serviceAccount:streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"
    ])
    error_message = "Each folder binding must grant the module's role to the hub's scanner service account."
  }

  assert {
    condition     = output.granted_on.scope == "folders" && toset(output.granted_on.ids) == toset(["111111111111", "222222222222"])
    error_message = "granted_on must name the folders."
  }
}

# Option C: IAM matches the projects selected in Stream exactly.
run "projects" {
  command = apply

  variables {
    grant_on = { project_ids = ["app-prod-123", "app-staging-456"] }
  }

  assert {
    condition = (
      length(google_organization_iam_member.target) == 0
      && length(google_folder_iam_member.target) == 0
      && toset(keys(google_project_iam_member.target)) == toset(["app-prod-123", "app-staging-456"])
    )
    error_message = "Granting on projects must bind each project, and nothing else."
  }

  assert {
    condition = alltrue([for id, b in google_project_iam_member.target :
      b.project == id
      && b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
      && b.member == "serviceAccount:streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"
    ])
    error_message = "Each project binding must grant the module's role to the hub's scanner service account."
  }

  assert {
    condition     = output.granted_on.scope == "projects" && toset(output.granted_on.ids) == toset(["app-prod-123", "app-staging-456"])
    error_message = "granted_on must name the projects."
  }
}

# For a scanner whose service account isn't the default, such as a suffixed
# instance's.
run "service_account_override" {
  command = apply

  variables {
    scanner_service_account_email = "streamsec-volume-scanner-stg@scanner-hub-123.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_organization_iam_member.target[0].member == "serviceAccount:streamsec-volume-scanner-stg@scanner-hub-123.iam.gserviceaccount.com"
    error_message = "An explicit scanner_service_account_email must be the one granted."
  }

  assert {
    condition     = output.scanner_service_account_email == "streamsec-volume-scanner-stg@scanner-hub-123.iam.gserviceaccount.com"
    error_message = "The output must name the service account granted."
  }
}
