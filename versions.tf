terraform {
  required_version = ">= 1.0"

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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}
