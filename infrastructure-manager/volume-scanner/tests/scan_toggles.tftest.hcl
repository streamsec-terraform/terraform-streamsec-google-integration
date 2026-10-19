mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# The console passes these as Infra Manager input values. A test can't read
# the module's resources from here; modules/volume-scanner's tests check the
# env they set.
run "data_disk_toggles_are_accepted" {
  command = plan

  variables {
    scan_data_volumes       = "False"
    scan_kubernetes_volumes = "TRUE"
  }
}

run "kubernetes_volumes_must_be_a_boolean_string" {
  command = plan

  variables {
    scan_kubernetes_volumes = "yes"
  }

  expect_failures = [var.scan_kubernetes_volumes]
}
