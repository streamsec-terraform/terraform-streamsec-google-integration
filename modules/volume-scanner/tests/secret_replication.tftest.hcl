# Automatic replication needs "global", which gcp.resourceLocations can
# disallow (DEV-23760).

mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "europe-west3"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

run "new_secrets_live_in_the_install_region" {
  command = plan

  assert {
    condition = alltrue([
      for s in [google_secret_manager_secret.collection_token, google_secret_manager_secret.ack_token] :
      length(s.replication[0].auto) == 0 && try(tolist(s.replication[0].user_managed[0].replicas[*].location) == tolist(["europe-west3"]), false)
    ])
    error_message = "Both secrets must have exactly one replica, in var.region, and no automatic replication."
  }
}

# A replaced secret loses its accessor binding (keyed on secret_id).
run "older_release" {
  state_key = "upgrade"

  module {
    source = "./tests/fixtures/auto_secrets"
  }
}

run "upgrade_keeps_automatic_secrets" {
  command   = plan
  state_key = "upgrade"

  assert {
    condition = alltrue([
      for s in [google_secret_manager_secret.collection_token, google_secret_manager_secret.ack_token] :
      length(s.replication[0].auto) == 1 && length(s.replication[0].user_managed) == 0
    ])
    error_message = "An existing install's automatic secrets must be kept, not replaced."
  }
}
