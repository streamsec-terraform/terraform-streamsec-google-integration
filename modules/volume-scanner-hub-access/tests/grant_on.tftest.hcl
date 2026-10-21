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
  hub_project_ids = ["scanner-hub-123"]
  org_id          = "123456789012"
}

# grant_on omitted: as the console's command without folders, every project of
# the organization, including ones created later.
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
    condition = alltrue([for b in google_organization_iam_member.target :
      b.org_id == "123456789012"
      && b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
      && b.member == "serviceAccount:streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"
    ])
    error_message = "The organization binding must grant the module's role to the hub's scanner service account."
  }

  assert {
    condition     = output.granted_on.scope == "organization" && toset(output.granted_on.ids) == toset(["123456789012"])
    error_message = "granted_on must name the organization."
  }

  assert {
    condition     = toset(output.scanner_service_account_emails) == toset(["streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"])
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

# Every hub of an organization reaches its projects through the one role, so
# one instance binds them all. Bindings are keyed by email, so adding or
# removing a hub leaves the others' bindings in place.
run "several_hubs_on_the_organization" {
  command = apply

  variables {
    hub_project_ids = ["hub-a-123456", "hub-b-123456"]
  }

  assert {
    condition = toset(keys(google_organization_iam_member.target)) == toset([
      "streamsec-volume-scanner@hub-a-123456.iam.gserviceaccount.com",
      "streamsec-volume-scanner@hub-b-123456.iam.gserviceaccount.com",
    ])
    error_message = "Each hub's scanner must get its own organization binding, keyed by its email."
  }

  assert {
    condition     = alltrue([for email, b in google_organization_iam_member.target : b.member == "serviceAccount:${email}"])
    error_message = "Each organization binding must grant the role to the service account it is keyed by."
  }

  assert {
    condition = toset(output.scanner_service_account_emails) == toset([
      "streamsec-volume-scanner@hub-a-123456.iam.gserviceaccount.com",
      "streamsec-volume-scanner@hub-b-123456.iam.gserviceaccount.com",
    ])
    error_message = "The output must list every service account bound."
  }
}

# Hubs and an explicit service account, such as a suffixed scanner's, on
# folders: every principal on every folder, keyed by folder and email.
run "several_hubs_on_folders" {
  command = apply

  variables {
    hub_project_ids                = ["hub-a-123456", "hub-b-123456"]
    scanner_service_account_emails = ["streamsec-volume-scanner-stg@hub-a-123456.iam.gserviceaccount.com"]
    grant_on                       = { folder_ids = ["111111111111", "222222222222"] }
  }

  assert {
    condition = (
      length(google_organization_iam_member.target) == 0
      && length(google_project_iam_member.target) == 0
      && toset(keys(google_folder_iam_member.target)) == toset([
        "111111111111/streamsec-volume-scanner@hub-a-123456.iam.gserviceaccount.com",
        "111111111111/streamsec-volume-scanner@hub-b-123456.iam.gserviceaccount.com",
        "111111111111/streamsec-volume-scanner-stg@hub-a-123456.iam.gserviceaccount.com",
        "222222222222/streamsec-volume-scanner@hub-a-123456.iam.gserviceaccount.com",
        "222222222222/streamsec-volume-scanner@hub-b-123456.iam.gserviceaccount.com",
        "222222222222/streamsec-volume-scanner-stg@hub-a-123456.iam.gserviceaccount.com",
      ])
    )
    error_message = "Granting on folders must bind every service account on every folder, and nothing else."
  }

  assert {
    condition = alltrue([for key, b in google_folder_iam_member.target :
      b.folder == "folders/${split("/", key)[0]}"
      && b.member == "serviceAccount:${split("/", key)[1]}"
      && b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
    ])
    error_message = "Each folder binding must grant the module's role on its folder to its service account."
  }

  assert {
    condition     = output.granted_on.scope == "folders" && toset(output.granted_on.ids) == toset(["111111111111", "222222222222"])
    error_message = "granted_on must name the folders."
  }

  assert {
    condition     = length(output.scanner_service_account_emails) == 3
    error_message = "The output must list the hubs' service accounts and the explicit one."
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
      && toset(keys(google_project_iam_member.target)) == toset([
        "app-prod-123/streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com",
        "app-staging-456/streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com",
      ])
    )
    error_message = "Granting on projects must bind the service account on each project, and nothing else."
  }

  assert {
    condition = alltrue([for key, b in google_project_iam_member.target :
      b.project == split("/", key)[0]
      && b.member == "serviceAccount:${split("/", key)[1]}"
      && b.role == "organizations/123456789012/roles/streamsecVolumeScannerTarget"
    ])
    error_message = "Each project binding must grant the module's role on its project to its service account."
  }

  assert {
    condition     = output.granted_on.scope == "projects" && toset(output.granted_on.ids) == toset(["app-prod-123", "app-staging-456"])
    error_message = "granted_on must name the projects."
  }
}

# A hub's account named both ways is one principal.
run "a_derived_email_given_again_binds_once" {
  command = apply

  variables {
    scanner_service_account_emails = ["streamsec-volume-scanner@scanner-hub-123.iam.gserviceaccount.com"]
  }

  assert {
    condition     = length(google_organization_iam_member.target) == 1 && length(output.scanner_service_account_emails) == 1
    error_message = "A hub's service account named both by hub_project_ids and by email must be bound once."
  }
}

run "service_accounts_without_hub_ids" {
  command = apply

  variables {
    hub_project_ids                = []
    scanner_service_account_emails = ["streamsec-volume-scanner-stg@scanner-hub-123.iam.gserviceaccount.com"]
  }

  assert {
    condition     = toset([for b in google_organization_iam_member.target : b.member]) == toset(["serviceAccount:streamsec-volume-scanner-stg@scanner-hub-123.iam.gserviceaccount.com"])
    error_message = "An explicit service account must be bound without any hub_project_ids."
  }
}

# The role created by the console's command, or by another stack: bind it by
# its name and leave it alone, so destroying this instance can't delete it.
run "role_owned_elsewhere" {
  command = apply

  variables {
    org_id      = "999999999999"
    create_role = false
  }

  assert {
    condition     = length(google_organization_iam_custom_role.target) == 0
    error_message = "With create_role = false the module must not manage the role."
  }

  assert {
    condition     = alltrue([for b in google_organization_iam_member.target : b.role == "organizations/999999999999/roles/streamsecVolumeScannerTarget"])
    error_message = "With create_role = false the bindings must name the organization's existing role."
  }

  assert {
    condition = (
      output.role_id == "streamsecVolumeScannerTarget"
      && output.role_name == "organizations/999999999999/roles/streamsecVolumeScannerTarget"
    )
    error_message = "The outputs must name the existing role."
  }
}
