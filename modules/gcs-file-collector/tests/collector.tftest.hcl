mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_data "google_storage_bucket" {
    defaults = {
      location       = "US"
      project_number = 123456789012
    }
  }
  mock_data "google_storage_project_service_account" {
    defaults = {
      email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    }
  }
}

mock_provider "archive" {}
mock_provider "time" {}

variables {
  project_id              = "acme-logs"
  bucket_name             = "acme-github-audit"
  api_url_suffix          = "github-audit"
  stream_api_url          = "https://acme.streamsec.io/"
  stream_collection_token = "collection-token"
}

run "reads_the_bucket_at_plan_so_its_checks_run_before_any_change" {
  # First, on empty state as on a first deploy, when nothing it might depend on exists yet.
  command = plan

  assert {
    condition     = google_cloudfunctions2_function.collector.event_trigger[0].trigger_region == "us"
    error_message = "The bucket must be read while planning, not deferred to the apply."
  }
}

run "delivers_each_new_object_in_the_bucket_to_the_function" {
  assert {
    condition     = google_cloudfunctions2_function.collector.event_trigger[0].event_type == "google.cloud.storage.object.v1.finalized"
    error_message = "The function must trigger on objects written to the bucket."
  }
  assert {
    condition = [for f in google_cloudfunctions2_function.collector.event_trigger[0].event_filters : {
      attribute = f.attribute, value = f.value
    }] == [{ attribute = "bucket", value = "acme-github-audit" }]
    error_message = "The trigger must filter on the bucket and nothing else."
  }
  assert {
    condition     = google_cloudfunctions2_function.collector.event_trigger[0].trigger_region == "us"
    error_message = "A Cloud Storage trigger must be in the bucket's location."
  }
  assert {
    condition     = google_cloudfunctions2_function.collector.event_trigger[0].retry_policy == "RETRY_POLICY_RETRY"
    error_message = "A failed delivery must be retried."
  }
  assert {
    condition     = google_cloudfunctions2_function.collector.event_trigger[0].service_account_email == google_service_account.collector.email
    error_message = "Events must be delivered as the collector's identity."
  }
  assert {
    condition     = google_cloud_run_v2_service_iam_member.trigger_invoker.member == "serviceAccount:${google_service_account.collector.email}"
    error_message = "The collector's identity must be able to invoke the function."
  }
  assert {
    condition     = google_storage_bucket_iam_member.collector_reader.bucket == "acme-github-audit" && google_storage_bucket_iam_member.collector_reader.role == "roles/storage.objectViewer"
    error_message = "The collector must be able to read the bucket's objects."
  }
  assert {
    condition     = google_project_iam_member.storage_agent_publisher[0].member == "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    error_message = "The Cloud Storage service agent must be able to publish the bucket's events."
  }
}

run "sends_each_file_to_the_collection_endpoint" {
  assert {
    condition = google_cloudfunctions2_function.collector.service_config[0].environment_variables == tomap({
      API_URL        = "https://acme.streamsec.io"
      API_URL_SUFFIX = "github-audit"
    })
    error_message = "The function must know the tenant URL and the endpoint."
  }
  assert {
    condition     = google_cloudfunctions2_function.collector.service_config[0].secret_environment_variables[0].key == "API_TOKEN" && google_cloudfunctions2_function.collector.service_config[0].secret_environment_variables[0].secret == google_secret_manager_secret.collection_token.secret_id
    error_message = "The collection token must come from Secret Manager."
  }
  assert {
    condition     = output.collection_url == "https://acme.streamsec.io/api/v1/collection/github-audit"
    error_message = "Unexpected collection URL."
  }
  assert {
    condition     = google_cloudfunctions2_function.collector.build_config[0].entry_point == "collect"
    error_message = "The entry point must be the function in function_source/main.py."
  }
}

run "refuses_a_bucket_in_another_project" {
  command = plan

  override_data {
    target = data.google_storage_bucket.logs
    values = {
      location       = "US"
      project_number = 999999999999
    }
  }

  expect_failures = [terraform_data.bucket_contract]
}

run "refuses_a_gs_url_for_the_bucket" {
  command = plan

  variables {
    bucket_name = "gs://acme-github-audit"
  }

  expect_failures = [var.bucket_name]
}

run "refuses_an_empty_token" {
  command = plan

  variables {
    stream_collection_token = " "
  }

  expect_failures = [var.stream_collection_token]
}

run "leaves_the_shared_storage_agent_grant_to_the_project_when_asked" {
  variables {
    grant_storage_agent_publisher = false
  }

  assert {
    condition     = length(google_project_iam_member.storage_agent_publisher) == 0
    error_message = "With grant_storage_agent_publisher = false the module must not own the project-wide grant."
  }
}

run "first_collector" {
  assert {
    condition     = output.function_name == "streamsec-github-audit-a9abc0"
    error_message = "Unexpected function name; scripts/deploy-gcs-file-collector.sh derives the same one."
  }
}

run "a_collector_id_gives_the_same_bucket_a_separate_collector" {
  # e.g. a second Stream workspace collecting from the same bucket
  variables {
    collector_id = "6123d08a995aa9a2a3f71c81"
  }

  assert {
    condition     = output.function_name == "streamsec-github-audit-58951c" && google_service_account.collector.account_id == "ss-col-github-audit-58951c"
    error_message = "A collector ID must give the collector names of its own."
  }
}

run "refuses_a_collector_id_that_is_not_an_id" {
  command = plan

  variables {
    collector_id = "workspace 1;"
  }

  expect_failures = [var.collector_id]
}

run "refuses_a_collector_id_that_starts_with_a_dash" {
  # The script would read it as a flag
  command = plan

  variables {
    collector_id = "-6123d08a"
  }

  expect_failures = [var.collector_id]
}

run "a_null_collector_id_keeps_the_names_without_one" {
  # e.g. passed through as try(x.id, null)
  variables {
    collector_id = null
  }

  assert {
    condition     = output.function_name == "streamsec-github-audit-a9abc0"
    error_message = "A null collector_id must mean none."
  }
}

run "a_second_bucket_gets_its_own_collector" {
  variables {
    bucket_name = "acme-gitlab-audit"
  }

  assert {
    condition     = output.function_name != run.first_collector.function_name && google_service_account.collector.account_id == "ss-col-github-audit-6eb8e0"
    error_message = "Collectors for two buckets must not share resources."
  }
  # The identities, grants and build resources were replaced, so the IAM waits run again.
  assert {
    condition     = time_sleep.iam_propagation.triggers["collector"] == "github-audit-6eb8e0"
    error_message = "The IAM wait must run again when the collector's resources are replaced."
  }
}

run "waits_for_iam_again_in_another_region" {
  variables {
    region                           = "europe-west1"
    deployment_service_account_email = "infra-manager@acme-logs.iam.gserviceaccount.com"
  }

  assert {
    condition     = time_sleep.iam_propagation.triggers["region"] == "europe-west1"
    error_message = "The build repository and source bucket move with the region, so the IAM wait must run again."
  }
  assert {
    condition     = time_sleep.deployer_iam_propagation[0].triggers["role"] == google_project_iam_custom_role.deployer[0].role_id
    error_message = "The runner's custom role must be waited for whenever it is replaced."
  }
}

run "names_fit_gcp_limits_for_a_long_endpoint" {
  variables {
    api_url_suffix = "azure-audit/events"
  }

  assert {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", google_service_account.collector.account_id)) && can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", google_service_account.build.account_id))
    error_message = "Service account IDs must be 6 to 30 characters."
  }
  assert {
    condition     = can(regex("^[a-z][a-z0-9-]{0,47}[a-z0-9]$", google_cloudfunctions2_function.collector.name))
    error_message = "Function names must fit a Cloud Run service name."
  }
  assert {
    condition     = length(google_storage_bucket.source.name) <= 63
    error_message = "Bucket names must be at most 63 characters."
  }
}

run "grants_resource_level_iam_only_to_a_given_runner" {
  assert {
    condition     = length(google_project_iam_custom_role.deployer) == 0
    error_message = "Without a runner, no custom role is needed."
  }
}

run "grants_the_infrastructure_manager_runner_resource_level_iam" {
  variables {
    deployment_service_account_email = "infra-manager@acme-logs.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_project_iam_member.deployer[0].member == "serviceAccount:infra-manager@acme-logs.iam.gserviceaccount.com"
    error_message = "The runner must get the custom role."
  }
  assert {
    condition     = contains(google_project_iam_custom_role.deployer[0].permissions, "storage.buckets.setIamPolicy")
    error_message = "The runner must be able to grant the collector read access to the bucket."
  }
}
