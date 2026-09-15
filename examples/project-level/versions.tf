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
    # Declared by the root module for the optional vertex-ai-logging module;
    # must be named here so the provider block in main.tf resolves to Mastercard/restapi.
    restapi = {
      source  = "Mastercard/restapi"
      version = ">= 3.0"
    }
  }
}
