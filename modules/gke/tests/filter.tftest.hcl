mock_provider "google" {}
mock_provider "streamsec" {}

variables {
  acked_project_ids     = { p1 = "p1", p2 = "p2" }
  org_level_sink        = true
  organization_id       = "123456789"
  project_for_resources = "p1"
  projects = {
    p1 = { project_id = "p1", name = "p1" }
    p2 = { project_id = "p2", name = "p2" }
  }
}

run "base_filter_unchanged" {
  command = plan

  assert {
    condition     = trimspace(local.base_filter) == trimspace(file("tests/fixtures/base_log_filter.txt"))
    error_message = "The base filter changed: update tests/fixtures/base_log_filter.txt if intended."
  }
}

run "org_no_scoping" {
  command = plan

  assert {
    condition     = local.sink_filter == trimspace(file("log_filter.txt"))
    error_message = "Without scoping the filter must be the base filter only."
  }

  assert {
    condition     = !endswith(local.sink_filter, "\n")
    error_message = "The filter must not end with a newline."
  }
}

run "org_include_projects" {
  command = plan

  variables {
    include_projects = ["p2", "p2"]
  }

  assert {
    condition     = length(split("(resource.labels.project_id=\"p2\")", local.sink_filter)) == 2
    error_message = "The project clause must appear exactly once."
  }
}

run "clusters" {
  command = plan

  variables {
    include_clusters = ["a", "b", "a"]
    exclude_clusters = ["c"]
  }

  assert {
    condition     = length(split("(resource.labels.cluster_name=\"a\" OR resource.labels.cluster_name=\"b\")", local.sink_filter)) == 2
    error_message = "The include clause must list each cluster once."
  }

  assert {
    condition     = strcontains(local.sink_filter, "-(resource.labels.cluster_name=\"c\")")
    error_message = "The exclude clause is missing."
  }
}

run "org_full_scoping_exact" {
  command = plan

  variables {
    include_projects = ["p1", "p2"]
    include_clusters = ["a", "b"]
    exclude_clusters = ["c"]
  }

  assert {
    condition = local.sink_filter == join("\n", [
      trimspace(file("log_filter.txt")),
      "(resource.labels.project_id=\"p1\" OR resource.labels.project_id=\"p2\")",
      "(resource.labels.cluster_name=\"a\" OR resource.labels.cluster_name=\"b\")",
      "-(resource.labels.cluster_name=\"c\")",
    ])
    error_message = "The filter must join base, project, include and exclude clauses with newlines."
  }
}

run "project_mode_projects" {
  command = plan

  variables {
    org_level_sink        = false
    organization_id       = null
    project_for_resources = ""
    include_projects      = ["p1"]
  }

  assert {
    condition     = tolist(keys(local.deploy_projects)) == tolist(["p1"])
    error_message = "Project mode must deploy only to the selected projects."
  }

  assert {
    condition     = !strcontains(local.sink_filter, "resource.labels.project_id")
    error_message = "Project mode must not add a project clause."
  }
}

run "include_not_in_projects" {
  command = plan

  variables {
    include_projects = ["nope"]
  }

  expect_failures = [terraform_data.inputs]
}

run "cluster_in_both_lists" {
  command = plan

  variables {
    include_clusters = ["a"]
    exclude_clusters = ["a"]
  }

  expect_failures = [terraform_data.inputs]
}

run "bad_cluster_name" {
  command = plan

  variables {
    include_clusters = ["a\" OR x"]
  }

  expect_failures = [terraform_data.inputs]
}

run "org_project_for_resources_not_integrated" {
  command = plan

  variables {
    project_for_resources = "px"
  }

  expect_failures = [terraform_data.inputs]
}

run "org_project_for_resources_empty" {
  command = plan

  variables {
    project_for_resources = ""
  }

  expect_failures = [terraform_data.inputs]
}

run "org_project_for_resources_not_read" {
  command = plan

  variables {
    project_for_resources = "p2"
  }

  assert {
    condition     = keys(data.google_project.this) == ["p2"] && keys(data.streamsec_gcp_project.this) == ["p2"]
    error_message = "The data sources must read only the integrated deploy project."
  }
}

run "org_without_organization_id" {
  command = plan

  variables {
    organization_id = null
  }

  expect_failures = [terraform_data.inputs]
}

run "project_mode_no_projects" {
  command = plan

  variables {
    org_level_sink        = false
    organization_id       = null
    project_for_resources = ""
    include_projects      = []
    projects              = {}
  }

  expect_failures = [terraform_data.inputs]
}

run "filter_too_long" {
  command = plan

  variables {
    include_clusters = [for i in range(600) : "cluster-${i}"]
  }

  expect_failures = [terraform_data.inputs]
}

run "filter_too_long_projects" {
  command = plan

  variables {
    projects              = { for i in range(290) : format("gke-project-%018d", i) => { project_id = format("gke-project-%018d", i), name = "p" } }
    include_projects      = [for i in range(290) : format("gke-project-%018d", i)]
    project_for_resources = "gke-project-000000000000000000"
  }

  expect_failures = [terraform_data.inputs]
}
