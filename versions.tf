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
    # provider resolves, but NOT configured. Every caller must supply a `provider "restapi"` block
    # with at least a `uri`, even when enable_vertex_ai_logging is false, because Terraform
    # validates the provider configuration regardless of use. Full configuration (auth headers)
    # is only needed when enabling Vertex AI logging. See the README and examples/basic.
    restapi = {
      source  = "Mastercard/restapi"
      version = ">= 3.0"
    }
  }
}
