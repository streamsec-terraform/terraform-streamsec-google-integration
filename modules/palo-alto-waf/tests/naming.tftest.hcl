mock_provider "archive" {}
mock_provider "google" {}
mock_provider "time" {}

variables {
  project_id               = "stream-test-123"
  region                   = "us-central1"
  stream_api_url           = "https://tenant.streamsec.io"
  stream_integration_token = "test-token"
  stream_template_version  = "v2.10.0"
  vpc_network              = "test-network"
  subnet                   = "test-subnet"
}

run "long_integration_id" {
  command = plan

  variables {
    integration_id = "Customer / Palo # Primary! With A Very Long Integration Identifier 0123456789"
  }

  assert {
    condition     = local.resource_suffix == "custom-1f660ddd"
    error_message = "Long integration IDs must use the first six sanitized characters plus the stable hash."
  }

  assert {
    condition = (
      length(local.function_name) <= 63 &&
      length(local.service_account_id) <= 30 &&
      length(local.build_account_id) <= 30 &&
      length(local.build_repository) <= 63 &&
      length(local.connector_name) <= 25 &&
      length(local.source_bucket_name) <= 63 &&
      length(local.deployer_role_id) <= 64
    )
    error_message = "Generated names must fit the strictest documented GCP length limits."
  }

  assert {
    condition = (
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", local.function_name)) &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", local.service_account_id)) &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", local.build_account_id)) &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", local.connector_name)) &&
      can(regex("^[A-Za-z0-9_]+$", local.deployer_role_id))
    )
    error_message = "Generated names must satisfy the relevant GCP character constraints."
  }
}

run "punctuation_only_integration_id" {
  command = plan

  variables {
    integration_id = "!!!"
  }

  assert {
    condition     = local.resource_suffix == "integr-e84c538e"
    error_message = "An integration ID without alphanumeric characters must receive a readable fallback plus its stable hash."
  }
}

run "punctuation_at_truncation_boundary" {
  command = plan

  variables {
    integration_id = "abcde/xyz"
  }

  assert {
    condition     = local.resource_suffix == "abcde-1a6f2e04"
    error_message = "A separator at the readable-prefix boundary must not produce a doubled hyphen."
  }
}

run "first_colliding_sanitized_id" {
  command = plan

  variables {
    integration_id = "customer/palo"
  }

  assert {
    condition     = local.resource_suffix == "custom-25c2dfa1"
    error_message = "The first punctuation variant must retain its full-ID hash."
  }
}

run "second_colliding_sanitized_id" {
  command = plan

  variables {
    integration_id = "customer-palo"
  }

  assert {
    condition     = local.resource_suffix == "custom-28cfe2bd"
    error_message = "Distinct IDs that sanitize identically must still produce distinct suffixes."
  }

  assert {
    condition     = local.resource_suffix != run.first_colliding_sanitized_id.resource_suffix
    error_message = "Two different integration IDs must not collide after sanitization."
  }
}
