mock_provider "google" {}

variables {
  hub_project_ids = ["scanner-hub-123"]
  org_id          = "123456789012"
}

run "org_id_must_be_digits" {
  command = plan

  variables {
    org_id = "organizations/123456789012"
  }

  expect_failures = [var.org_id]
}

run "org_id_must_not_be_empty" {
  command = plan

  variables {
    org_id = ""
  }

  expect_failures = [var.org_id]
}

run "hub_project_ids_must_be_project_ids" {
  command = plan

  variables {
    hub_project_ids = ["scanner-hub-123", "Scanner_Hub"]
  }

  expect_failures = [var.hub_project_ids]
}

run "hub_project_ids_must_not_be_too_short" {
  command = plan

  variables {
    hub_project_ids = ["hub"]
  }

  expect_failures = [var.hub_project_ids]
}

run "service_account_emails_must_be_service_accounts" {
  command = plan

  variables {
    scanner_service_account_emails = ["streamsec-volume-scanner-stg@scanner-hub-123.iam.gserviceaccount.com", "someone@example.com"]
  }

  expect_failures = [var.scanner_service_account_emails]
}

# Neither a hub nor a service account: nothing to grant the role to.
run "at_least_one_principal" {
  command = plan

  variables {
    hub_project_ids = []
  }

  expect_failures = [output.scanner_service_account_emails]
}

run "folder_ids_must_be_digits" {
  command = plan

  variables {
    grant_on = { folder_ids = ["111111111111", "folders/222222222222"] }
  }

  expect_failures = [var.grant_on]
}

run "project_ids_must_be_project_ids" {
  command = plan

  variables {
    grant_on = { project_ids = ["app-prod-123", "App_Prod"] }
  }

  expect_failures = [var.grant_on]
}

# Omitted, grant_on means the organization. An explicit null is refused
# rather than read the same way: a null computed by mistake would otherwise
# widen the grant to every project.
run "a_null_grant_on_is_rejected" {
  command = plan

  variables {
    grant_on = null
  }

  expect_failures = [var.grant_on]
}

# Zero places. An empty list must not fall back to the organization: a list
# computed empty by mistake would otherwise widen the grant to every project.
run "nowhere_is_rejected" {
  command = plan

  variables {
    grant_on = {}
  }

  expect_failures = [var.grant_on]
}

run "an_empty_folder_list_is_rejected" {
  command = plan

  variables {
    grant_on = { folder_ids = [] }
  }

  expect_failures = [var.grant_on]
}

run "an_empty_project_list_is_rejected" {
  command = plan

  variables {
    grant_on = { project_ids = [] }
  }

  expect_failures = [var.grant_on]
}

run "organization_off_alone_is_rejected" {
  command = plan

  variables {
    grant_on = { organization = false }
  }

  expect_failures = [var.grant_on]
}

# More than one place.
run "organization_and_folders_are_rejected" {
  command = plan

  variables {
    grant_on = { organization = true, folder_ids = ["111111111111"] }
  }

  expect_failures = [var.grant_on]
}

run "organization_and_projects_are_rejected" {
  command = plan

  variables {
    grant_on = { organization = true, project_ids = ["app-prod-123"] }
  }

  expect_failures = [var.grant_on]
}

run "folders_and_projects_are_rejected" {
  command = plan

  variables {
    grant_on = { folder_ids = ["111111111111"], project_ids = ["app-prod-123"] }
  }

  expect_failures = [var.grant_on]
}
