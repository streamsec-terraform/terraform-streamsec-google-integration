mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# A hub's scanner reads each project it covers with Resource Manager's
# projects.get, which also gives the project number. Resource
# Manager is a client-based API: it must be enabled in the project of the
# caller's credentials, the hub, not in the project being read. The other
# cross-project calls (Compute, Cloud Run, Cloud Functions, image pulls) are
# resource-based, so the scanned project's own APIs serve them.
run "every_required_api_is_enabled" {
  command = plan

  assert {
    condition = toset(keys(google_project_service.apis)) == toset([
      "compute.googleapis.com",
      "batch.googleapis.com",
      "run.googleapis.com",
      "cloudscheduler.googleapis.com",
      "secretmanager.googleapis.com",
      "cloudresourcemanager.googleapis.com",
    ])
    error_message = "The scanner's project must enable exactly the APIs it calls with its own credentials, Resource Manager included."
  }

  assert {
    condition     = alltrue([for s in google_project_service.apis : s.project == "stream-test-123"])
    error_message = "Every API must be enabled in the scanner's own project."
  }

  assert {
    condition     = alltrue([for s in google_project_service.apis : s.disable_on_destroy == false])
    error_message = "Removing the scanner must never disable APIs the project may rely on."
  }
}
