terraform {
  required_version = ">= 1.0"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.8"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}
