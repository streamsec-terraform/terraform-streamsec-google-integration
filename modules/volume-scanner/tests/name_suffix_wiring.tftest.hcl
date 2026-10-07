# Isolation rests on cross-references, not only names: the scheduler must run
# this instance's job, and the job must launch workers as this instance's
# service account on this instance's network. Those values are computed, so
# this needs an apply against the mock provider. stream_api_url points at a
# closed local port so the acknowledgement's non-fatal curl reaches nothing.

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email     = "streamsec-volume-scanner-stg@stream-test-123.iam.gserviceaccount.com"
      name      = "projects/stream-test-123/serviceAccounts/streamsec-volume-scanner-stg@stream-test-123.iam.gserviceaccount.com"
      id        = "projects/stream-test-123/serviceAccounts/streamsec-volume-scanner-stg@stream-test-123.iam.gserviceaccount.com"
      member    = "serviceAccount:streamsec-volume-scanner-stg@stream-test-123.iam.gserviceaccount.com"
      unique_id = "123456789012345678901"
    }
  }
  mock_resource "google_project_iam_custom_role" {
    defaults = {
      id   = "projects/stream-test-123/roles/streamsecVolumeScanner_stg"
      name = "projects/stream-test-123/roles/streamsecVolumeScanner_stg"
    }
  }
  mock_resource "google_compute_network" {
    defaults = {
      id        = "projects/stream-test-123/global/networks/streamsec-scanner-vpc-stg"
      self_link = "https://www.googleapis.com/compute/v1/projects/stream-test-123/global/networks/streamsec-scanner-vpc-stg"
    }
  }
  mock_resource "google_compute_subnetwork" {
    defaults = {
      id        = "projects/stream-test-123/regions/us-central1/subnetworks/streamsec-scanner-subnet-stg"
      self_link = "https://www.googleapis.com/compute/v1/projects/stream-test-123/regions/us-central1/subnetworks/streamsec-scanner-subnet-stg"
    }
  }
  mock_resource "google_compute_router" {
    defaults = {
      id = "projects/stream-test-123/regions/us-central1/routers/streamsec-scanner-router-stg"
    }
  }
  mock_resource "google_secret_manager_secret" {
    defaults = {
      id   = "projects/stream-test-123/secrets/streamsec-volume-scanner-stg-collection-token"
      name = "projects/123456789012/secrets/streamsec-volume-scanner-stg-collection-token"
    }
  }
  mock_resource "google_secret_manager_secret_version" {
    defaults = {
      id      = "projects/stream-test-123/secrets/streamsec-volume-scanner-stg-collection-token/versions/2"
      name    = "projects/123456789012/secrets/streamsec-volume-scanner-stg-collection-token/versions/2"
      version = "2"
    }
  }
  mock_resource "google_cloud_run_v2_job" {
    defaults = {
      id = "projects/stream-test-123/locations/us-central1/jobs/streamsec-volume-scanner-orchestrator-stg"
    }
  }
}

override_resource {
  target = google_secret_manager_secret_version.ack_token
  values = {
    name = "projects/123456789012/secrets/streamsec-volume-scanner-stg-ack-token/versions/1"
  }
}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "http://127.0.0.1:9"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
  name_suffix             = "-stg"
  scan_workload_only      = "true"
}

run "suffixed_instance_references_only_its_own_resources" {
  command = apply

  assert {
    condition     = endswith(google_cloud_scheduler_job.cron.http_target[0].uri, "/jobs/streamsec-volume-scanner-orchestrator-stg:run")
    error_message = "The scheduler must run this instance's own orchestrator job."
  }

  assert {
    condition = (
      one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_GCP_WORKER_SA"]) == google_service_account.scanner.email
      && one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_GCP_WORKER_NETWORK"]) == google_compute_network.scanner.id
      && one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_GCP_WORKER_SUBNETWORK"]) == google_compute_subnetwork.scanner.id
    )
    error_message = "Workers must run as this instance's service account on this instance's network."
  }

  assert {
    condition = (
      one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_STREAM_SCAN_TOKEN_SECRET"]) == google_secret_manager_secret_version.collection_token.name
      && google_secret_manager_secret_version.collection_token.secret == google_secret_manager_secret.collection_token.id
    )
    error_message = "Workers must read the token from this instance's own collection-token secret version."
  }
}
