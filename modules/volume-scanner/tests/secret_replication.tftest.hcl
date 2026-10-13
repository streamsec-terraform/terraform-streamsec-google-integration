# Automatic replication needs "global", which a gcp.resourceLocations policy can disallow (DEV-23760).

mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "europe-west3"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# A new default would replace the secrets of every install that re-applies.
run "automatic_by_default" {
  command = plan

  assert {
    condition = alltrue([for s in [google_secret_manager_secret.collection_token, google_secret_manager_secret.ack_token] :
    length(s.replication[0].auto) == 1 && length(s.replication[0].user_managed) == 0])
    error_message = "Both secrets must keep automatic replication unless secret_replication says otherwise."
  }
}

run "region_keeps_both_secrets_in_the_install_region" {
  command = plan

  variables {
    secret_replication = "region"
  }

  assert {
    condition = alltrue([for s in [google_secret_manager_secret.collection_token, google_secret_manager_secret.ack_token] :
    length(s.replication[0].auto) == 0 && try(tolist(s.replication[0].user_managed[0].replicas[*].location) == tolist(["europe-west3"]), false)])
    error_message = "With secret_replication = \"region\", both secrets must have exactly one replica, in var.region."
  }
}

run "replication_must_be_known" {
  command = plan

  variables {
    secret_replication = "europe-west3"
  }

  expect_failures = [var.secret_replication]
}
