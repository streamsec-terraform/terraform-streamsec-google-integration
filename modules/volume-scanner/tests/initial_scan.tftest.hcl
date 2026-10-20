# The install starts one scan instead of leaving the first to the schedule.
# Applied against the mock provider, so the trigger's curl really runs: with a
# network, Cloud Run rejects the mock token. Either way the apply must succeed.

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email     = "streamsec-volume-scanner@stream-test-123.iam.gserviceaccount.com"
      name      = "projects/stream-test-123/serviceAccounts/streamsec-volume-scanner@stream-test-123.iam.gserviceaccount.com"
      unique_id = "123456789012345678901"
    }
  }
  mock_resource "google_cloud_run_v2_job" {
    defaults = {
      uid = "0a1b2c3d-job-uid"
    }
  }
}

mock_provider "time" {}

variables {
  project_id              = "stream-test-123"
  region                  = "europe-west1"
  stream_api_url          = "http://127.0.0.1:9"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

run "starts_this_install_s_job_once" {
  command = apply

  assert {
    condition     = terraform_data.initial_scan.input == "https://run.googleapis.com/v2/projects/stream-test-123/locations/europe-west1/jobs/streamsec-volume-scanner-orchestrator"
    error_message = "The initial scan must start this install's orchestrator job, in its region."
  }

  # Only a new job scans again: keyed on the template version too, every
  # Update scanner run would start another scan.
  assert {
    condition     = length(terraform_data.initial_scan.triggers_replace) == 1 && terraform_data.initial_scan.triggers_replace[0] == google_cloud_run_v2_job.orchestrator.uid
    error_message = "The initial scan must run once per orchestrator job, and on nothing else."
  }

  # A recreated service account has new grants, so the wait must run again.
  assert {
    condition     = time_sleep.iam_propagation.triggers.service_account == google_service_account.scanner.unique_id
    error_message = "A new scanner service account must wait for its grants again."
  }
}

run "a_suffixed_instance_starts_its_own_job" {
  command = plan

  variables {
    name_suffix        = "-stg"
    scan_workload_only = "true"
  }

  assert {
    condition     = endswith(terraform_data.initial_scan.input, "/jobs/streamsec-volume-scanner-orchestrator-stg")
    error_message = "A suffixed instance must start its own orchestrator job."
  }
}
