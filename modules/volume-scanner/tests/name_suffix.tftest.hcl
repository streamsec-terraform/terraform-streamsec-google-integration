mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# Without a suffix every name is the one existing deployments already have, so
# re-applying them plans no rename.
run "default_names_are_unchanged" {
  command = plan

  assert {
    condition = (
      google_service_account.scanner.account_id == "streamsec-volume-scanner"
      && google_project_iam_custom_role.scanner.role_id == "streamsecVolumeScanner"
      && google_cloud_run_v2_job.orchestrator.name == "streamsec-volume-scanner-orchestrator"
      && google_cloud_scheduler_job.cron.name == "streamsec-volume-scanner-cron"
      && google_secret_manager_secret.collection_token.secret_id == "streamsec-volume-scanner-collection-token"
      && google_secret_manager_secret.ack_token.secret_id == "streamsec-volume-scanner-ack-token"
      && google_compute_network.scanner.name == "streamsec-scanner-vpc"
      && google_compute_subnetwork.scanner.name == "streamsec-scanner-subnet"
      && google_compute_router.scanner.name == "streamsec-scanner-router"
      && google_compute_router_nat.scanner.name == "streamsec-scanner-nat"
    )
    error_message = "Without name_suffix every resource must keep its existing name."
  }
}

# A second, workload-only instance in the same project: every project-unique
# name carries the suffix, so nothing collides with the first instance.
run "suffixed_instance_renames_everything" {
  command = plan

  variables {
    name_suffix        = "-stg"
    scan_workload_only = "true"
  }

  assert {
    condition = (
      google_service_account.scanner.account_id == "streamsec-volume-scanner-stg"
      && google_project_iam_custom_role.scanner.role_id == "streamsecVolumeScanner_stg"
      && google_cloud_run_v2_job.orchestrator.name == "streamsec-volume-scanner-orchestrator-stg"
      && google_cloud_scheduler_job.cron.name == "streamsec-volume-scanner-cron-stg"
      && google_secret_manager_secret.collection_token.secret_id == "streamsec-volume-scanner-stg-collection-token"
      && google_secret_manager_secret.ack_token.secret_id == "streamsec-volume-scanner-stg-ack-token"
      && google_compute_network.scanner.name == "streamsec-scanner-vpc-stg"
      && google_compute_subnetwork.scanner.name == "streamsec-scanner-subnet-stg"
      && google_compute_router.scanner.name == "streamsec-scanner-router-stg"
      && google_compute_router_nat.scanner.name == "streamsec-scanner-nat-stg"
    )
    error_message = "With name_suffix every project-unique name must carry the suffix."
  }
}

# Disk-scanning snapshots are labelled for the scanner, not for an instance, so
# a suffixed instance that also scanned disks would delete the first one's.
run "suffixed_instance_must_be_workload_only" {
  command = plan

  variables {
    name_suffix = "-stg"
  }

  expect_failures = [google_cloud_run_v2_job.orchestrator]
}

run "suffix_too_long_for_the_service_account_id" {
  command = plan

  variables {
    name_suffix        = "-staging"
    scan_workload_only = "true"
  }

  expect_failures = [var.name_suffix]
}
