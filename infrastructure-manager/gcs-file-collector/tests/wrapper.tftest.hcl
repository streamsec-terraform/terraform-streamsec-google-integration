mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_data "google_storage_bucket" {
    defaults = {
      location       = "US-CENTRAL1"
      project_number = 123456789012
    }
  }
}

mock_provider "archive" {}
mock_provider "time" {}

variables {
  project_id              = "acme-logs"
  bucket_name             = "acme-github-audit"
  api_url_suffix          = "github-audit"
  stream_api_url          = "https://acme.streamsec.io"
  stream_collection_token = "collection-token"
}

run "deploys_the_collector_as_the_console_command_expects" {
  assert {
    condition     = module.gcs_file_collector.collection_url == "https://acme.streamsec.io/api/v1/collection/github-audit"
    error_message = "The wrapper must pass the tenant URL and endpoint through."
  }
  assert {
    condition     = module.gcs_file_collector.function_name == "streamsec-github-audit-a9abc0"
    error_message = "The console names the Infrastructure Manager deployment after the function."
  }
}

run "lets_the_infrastructure_manager_runner_set_resource_iam" {
  # Without the runner's custom role, the first apply fails on the bucket's setIamPolicy.
  assert {
    condition     = module.gcs_file_collector.deployer_role != null
    error_message = "The runner must get the module's custom role."
  }
}

run "rejects_an_invalid_project_id" {
  command = plan

  variables {
    project_id = "Acme_Logs"
  }

  expect_failures = [var.project_id]
}
