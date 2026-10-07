# The orchestrator launches its workers as Batch jobs, and a plain variable on
# a Batch job is readable by anyone with batch.jobs.get, which the basic Viewer
# role has. The scanner passes the collection token to its workers as a Batch
# secret variable when the orchestrator names the token's secret version, so
# that name must be the exact version this instance created (DEV-23067). It is
# computed, so this needs an apply against the mock provider. stream_api_url
# points at a closed local port so the acknowledgement's non-fatal curl
# reaches nothing.

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "streamsec-volume-scanner@stream-test-123.iam.gserviceaccount.com"
      name  = "projects/stream-test-123/serviceAccounts/streamsec-volume-scanner@stream-test-123.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_secret_manager_secret" {
    defaults = {
      name = "projects/123456789012/secrets/streamsec-volume-scanner-collection-token"
    }
  }
  mock_resource "google_secret_manager_secret_version" {
    defaults = {
      id      = "projects/stream-test-123/secrets/streamsec-volume-scanner-collection-token/versions/7"
      name    = "projects/123456789012/secrets/streamsec-volume-scanner-collection-token/versions/7"
      version = "7"
    }
  }
}

# The ack token's version gets a name of its own, so wiring the variable to it
# fails here.
override_resource {
  target = google_secret_manager_secret_version.ack_token
  values = {
    name = "projects/123456789012/secrets/streamsec-volume-scanner-ack-token/versions/3"
  }
}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "http://127.0.0.1:9"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

run "default_instance_names_its_token_version" {
  command = apply

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_STREAM_SCAN_TOKEN_SECRET"]) == google_secret_manager_secret_version.collection_token.name
    error_message = "The orchestrator must name the collection token's exact secret version, so its Batch workers read the token from Secret Manager."
  }

  assert {
    condition     = google_secret_manager_secret_version.collection_token.secret == google_secret_manager_secret.collection_token.id
    error_message = "The named version must belong to this instance's collection-token secret."
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value_source[0].secret_key_ref[0].secret if e.name == "COLLECTOR_STREAM_SCAN_TOKEN"]) == google_secret_manager_secret.collection_token.secret_id
    error_message = "The orchestrator itself must still read the token from Secret Manager."
  }
}
