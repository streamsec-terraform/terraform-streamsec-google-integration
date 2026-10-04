mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# The scanner reads its GCP workload kinds from COLLECTOR_WORKLOAD_KINDS. With
# none of its own set it falls back to the AWS and Azure kinds, which do nothing
# on GCP, so the module has to set it. By default every GCP kind is on, and the
# role grants each kind's permissions.
run "every_kind_by_default" {
  command = plan

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_WORKLOAD_KINDS"]) == "cloudrun,cloudrunjobs,cloudfunctions"
    error_message = "COLLECTOR_WORKLOAD_KINDS must list every GCP kind by default."
  }

  assert {
    condition = length(setsubtract([
      "run.locations.list",
      "run.services.list",
      "run.revisions.get",
      "run.jobs.list",
      "cloudfunctions.functions.list",
      "cloudfunctions.functions.sourceCodeGet",
      "artifactregistry.repositories.downloadArtifacts",
    ], google_project_iam_custom_role.scanner.permissions)) == 0
    error_message = "The role must grant every permission the default kinds use."
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_WORKLOAD_ONLY"]) == "false"
    error_message = "VM disks are scanned unless scan_workload_only is set."
  }
}

# With every kind off the scanner gets "none": an unset variable would mean its
# defaults. The role then keeps none of the workload permissions.
run "no_kinds" {
  command = plan

  variables {
    scan_cloud_run       = "false"
    scan_cloud_run_jobs  = "false"
    scan_cloud_functions = "false"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_WORKLOAD_KINDS"]) == "none"
    error_message = "With every kind off, COLLECTOR_WORKLOAD_KINDS must be \"none\"."
  }

  assert {
    condition     = length([for p in google_project_iam_custom_role.scanner.permissions : p if startswith(p, "run.") || startswith(p, "cloudfunctions.") || startswith(p, "artifactregistry.")]) == 0
    error_message = "With every kind off, the role must grant no workload permission."
  }
}

# A kind turned off takes its access with it. Functions only: no Cloud Run or
# registry access.
run "functions_only" {
  command = plan

  variables {
    scan_cloud_run      = "false"
    scan_cloud_run_jobs = "false"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_WORKLOAD_KINDS"]) == "cloudfunctions"
    error_message = "Only the cloudfunctions kind must be set."
  }

  assert {
    condition = (
      contains(google_project_iam_custom_role.scanner.permissions, "cloudfunctions.functions.sourceCodeGet")
      && !contains(google_project_iam_custom_role.scanner.permissions, "run.locations.list")
      && !contains(google_project_iam_custom_role.scanner.permissions, "artifactregistry.repositories.downloadArtifacts")
    )
    error_message = "Scanning functions only must grant function access but no Cloud Run or registry access."
  }
}

# sourceCodeGet reads every function's source, so it goes when functions do.
run "cloud_run_without_functions" {
  command = plan

  variables {
    scan_cloud_functions = "False"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_WORKLOAD_KINDS"]) == "cloudrun,cloudrunjobs"
    error_message = "Only the Cloud Run kinds must be set."
  }

  assert {
    condition     = !contains(google_project_iam_custom_role.scanner.permissions, "cloudfunctions.functions.sourceCodeGet")
    error_message = "Without functions scanning the role must not read function source."
  }
}

run "workload_only" {
  command = plan

  variables {
    scan_workload_only = "TRUE"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_WORKLOAD_ONLY"]) == "true"
    error_message = "scan_workload_only must reach the orchestrator as COLLECTOR_WORKLOAD_ONLY=true."
  }
}

# Workload-only skips VM disks, so with every kind off it would scan nothing.
run "workload_only_needs_a_kind" {
  command = plan

  variables {
    scan_workload_only   = "true"
    scan_cloud_run       = "false"
    scan_cloud_run_jobs  = "false"
    scan_cloud_functions = "false"
  }

  expect_failures = [google_cloud_run_v2_job.orchestrator]
}

# Each Cloud Run kind on its own gets exactly its own workload permissions: a
# jobs-only install without run.locations.list fails every night, and one with
# run.services.list is over-granted.
run "cloud_run_services_only" {
  command = plan

  variables {
    scan_cloud_run_jobs  = "false"
    scan_cloud_functions = "false"
  }

  assert {
    condition = toset([for p in google_project_iam_custom_role.scanner.permissions : p if startswith(p, "run.") || startswith(p, "cloudfunctions.") || startswith(p, "artifactregistry.")]) == toset([
      "run.locations.list",
      "run.services.list",
      "run.revisions.get",
      "artifactregistry.repositories.downloadArtifacts",
    ])
    error_message = "Scanning Cloud Run services only must grant exactly the services permissions."
  }
}

run "cloud_run_jobs_only" {
  command = plan

  variables {
    scan_cloud_run       = "false"
    scan_cloud_functions = "false"
  }

  assert {
    condition = toset([for p in google_project_iam_custom_role.scanner.permissions : p if startswith(p, "run.") || startswith(p, "cloudfunctions.") || startswith(p, "artifactregistry.")]) == toset([
      "run.locations.list",
      "run.jobs.list",
      "artifactregistry.repositories.downloadArtifacts",
    ])
    error_message = "Scanning Cloud Run jobs only must grant exactly the jobs permissions."
  }
}

# The workload permissions are added to the disk-scanning ones, never instead.
run "keeps_the_disk_scanning_permissions" {
  command = plan

  assert {
    condition = length(setsubtract([
      "compute.instances.list",
      "compute.instances.attachDisk",
      "compute.disks.create",
      "compute.snapshots.delete",
      "batch.jobs.create",
      "logging.logEntries.create",
    ], google_project_iam_custom_role.scanner.permissions)) == 0
    error_message = "The disk-scanning permissions must stay in the role."
  }

  assert {
    condition     = length(google_project_iam_custom_role.scanner.permissions) == 25 + 7
    error_message = "By default the role holds the 25 disk-scanning permissions plus the 7 workload ones."
  }
}
