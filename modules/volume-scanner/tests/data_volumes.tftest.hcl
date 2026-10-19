mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# The scanner reads only the boot disk unless COLLECTOR_SCAN_DATA_VOLUMES is
# "true", and Batch workers inherit it from the orchestrator.
run "data_volumes_by_default" {
  command = plan

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_SCAN_DATA_VOLUMES"]) == "true"
    error_message = "COLLECTOR_SCAN_DATA_VOLUMES must be \"true\" by default."
  }
}

run "data_volumes_off" {
  command = plan

  variables {
    scan_data_volumes = "False"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_SCAN_DATA_VOLUMES"]) == "false"
    error_message = "scan_data_volumes = \"False\" must reach the orchestrator as COLLECTOR_SCAN_DATA_VOLUMES=false."
  }
}

# A suffixed instance holds no disk permissions, so it never scans data disks,
# whatever it is asked for.
run "suffixed_instance_never_scans_data_volumes" {
  command = plan

  variables {
    name_suffix        = "-stg"
    scan_workload_only = "true"
    scan_data_volumes  = "true"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_SCAN_DATA_VOLUMES"]) == "false"
    error_message = "A suffixed instance must get COLLECTOR_SCAN_DATA_VOLUMES=false."
  }
}

run "data_volumes_must_be_a_boolean_string" {
  command = plan

  variables {
    scan_data_volumes = "yes"
  }

  expect_failures = [var.scan_data_volumes]
}

# A pod's persistent volume is a data disk of the node it runs on; the scanner
# skips it unless COLLECTOR_SCAN_KUBERNETES_VOLUMES is "true".
run "kubernetes_volumes_skipped_by_default" {
  command = plan

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_SCAN_KUBERNETES_VOLUMES"]) == "false"
    error_message = "COLLECTOR_SCAN_KUBERNETES_VOLUMES must be \"false\" by default."
  }
}

run "kubernetes_volumes_on" {
  command = plan

  variables {
    scan_kubernetes_volumes = "TRUE"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_SCAN_KUBERNETES_VOLUMES"]) == "true"
    error_message = "scan_kubernetes_volumes = \"TRUE\" must reach the orchestrator as COLLECTOR_SCAN_KUBERNETES_VOLUMES=true."
  }
}

run "kubernetes_volumes_must_be_a_boolean_string" {
  command = plan

  variables {
    scan_kubernetes_volumes = "1"
  }

  expect_failures = [var.scan_kubernetes_volumes]
}

run "suffixed_instance_never_scans_kubernetes_volumes" {
  command = plan

  variables {
    name_suffix             = "-stg"
    scan_workload_only      = "true"
    scan_kubernetes_volumes = "true"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_SCAN_KUBERNETES_VOLUMES"]) == "false"
    error_message = "A suffixed instance must get COLLECTOR_SCAN_KUBERNETES_VOLUMES=false."
  }
}
