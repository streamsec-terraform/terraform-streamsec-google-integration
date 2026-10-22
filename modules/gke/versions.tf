terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.10"
    }
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.13"
    }
  }
}
