mock_provider "google" {}

variables {
  hub_project_id = "scanner-hub-123"
  org_id         = "123456789012"
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

run "hub_project_id_must_be_a_project_id" {
  command = plan

  variables {
    hub_project_id = "Scanner_Hub"
  }

  expect_failures = [var.hub_project_id]
}

run "hub_project_id_must_not_be_too_short" {
  command = plan

  variables {
    hub_project_id = "hub"
  }

  expect_failures = [var.hub_project_id]
}

run "service_account_must_be_a_service_account" {
  command = plan

  variables {
    scanner_service_account_email = "someone@example.com"
  }

  expect_failures = [var.scanner_service_account_email]
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
