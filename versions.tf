terraform {
  required_version = ">= 1.5"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.13"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.10"
    }
  }
}
