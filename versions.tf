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
    # Used only by modules/vertex-ai-logging, to call aiplatform's :setPublisherModelConfig (no
    # native Google-provider resource exists for publisher-model logging). Declared here so the
    # provider resolves, but NOT configured: callers that set enable_vertex_ai_logging = true must
    # supply a configured `restapi` provider in their own root. See the README.
    restapi = {
      source  = "Mastercard/restapi"
      version = ">= 3.0"
    }
  }
}
