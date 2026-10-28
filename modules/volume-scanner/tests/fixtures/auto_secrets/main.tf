# The token secrets as older releases created them.
terraform {
  required_version = ">= 1.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

resource "google_secret_manager_secret" "collection_token" {
  project   = "stream-test-123"
  secret_id = "streamsec-volume-scanner-collection-token"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "ack_token" {
  project   = "stream-test-123"
  secret_id = "streamsec-volume-scanner-ack-token"
  replication {
    auto {}
  }
}
