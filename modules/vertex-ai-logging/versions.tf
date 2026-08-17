terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
    # time_sleep, to let a just-enabled project API propagate before consumers use it.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.10"
    }
    # Drives aiplatform's :setPublisherModelConfig, which has no native Google-provider resource
    # (see the comment on restapi_object.publisher_model_logging in main.tf). Only required when
    # enable_request_response_logging is true.
    #
    # NOTE: this module deliberately declares the provider without CONFIGURING it. A module that
    # contains its own provider block cannot be used with count/for_each/depends_on, and the root
    # module wires this one with both `count` and `depends_on`. The caller must therefore supply a
    # configured `restapi` provider (see README).
    restapi = {
      source  = "Mastercard/restapi"
      version = ">= 3.0"
    }
  }
}
