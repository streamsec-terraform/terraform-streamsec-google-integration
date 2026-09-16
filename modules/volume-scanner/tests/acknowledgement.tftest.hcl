mock_provider "google" {}

# The install ack is the only way Stream learns a project's deployed template
# version. It previously pointed at the /api gateway, which has no auth bypass
# for the GCP path and answered 500 "No authorized" — and because the ack
# provisioner is deliberately non-fatal, every apply stayed green while the
# backend recorded nothing. Pin the URL so a revert to the gateway path fails
# here rather than silently in production (DEV-21196).

run "acknowledgement_contract" {
  command = plan

  variables {
    project_id              = "stream-test-123"
    region                  = "us-central1"
    stream_api_url          = "https://tenant.streamsec.io"
    stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
    stream_ack_token        = "test-ack-token"
    stream_collection_token = "test-collection-token"
    stream_template_version = "v2.12.0"
  }

  assert {
    condition     = local.stream_ack_url == "https://tenant.streamsec.io/scanner-callback/gcp/stream-test-123/acknowledge"
    error_message = "The scanner acknowledgement must post to the ms_api scanner-callback route, not the /api gateway."
  }

  assert {
    condition     = jsondecode(local.stream_ack_payload).template_version == "v2.12.0"
    error_message = "The acknowledgement payload must carry the deployed template version."
  }

  assert {
    condition     = jsondecode(local.stream_ack_payload).customer_id == "66fb95548de1fcbdf0ca10e5"
    error_message = "The acknowledgement payload must carry the customer id, which selects the tenant database."
  }

  assert {
    condition     = contains(terraform_data.acknowledge.triggers_replace, "v2.12.0")
    error_message = "Changing the template version must cause Terraform to acknowledge again."
  }

  # Without this, a deployment re-applied at an unchanged job and version keeps
  # the old resource and never calls the new endpoint.
  assert {
    condition     = contains(terraform_data.acknowledge.triggers_replace, local.stream_ack_url)
    error_message = "Changing the acknowledgement endpoint must cause Terraform to acknowledge again."
  }
}

# stream_api_url legitimately arrives with a trailing slash (the palo-alto-waf
# module's own test passes one). Left unnormalised it yields a double slash and
# a 404 that the non-fatal provisioner swallows.
run "normalises_a_trailing_slash_on_the_api_url" {
  command = plan

  variables {
    project_id              = "stream-test-123"
    region                  = "us-central1"
    stream_api_url          = "https://tenant.streamsec.io/"
    stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
    stream_ack_token        = "test-ack-token"
    stream_collection_token = "test-collection-token"
    stream_template_version = "v2.12.0"
  }

  assert {
    condition     = local.stream_ack_url == "https://tenant.streamsec.io/scanner-callback/gcp/stream-test-123/acknowledge"
    error_message = "A trailing slash on stream_api_url must not produce a double slash in the callback URL."
  }
}

# stream_template_version defaults to empty, and an empty version must be
# omitted from the payload entirely rather than sent as "" — the backend reads
# absent as unknown, but would record an empty string as a real version.
run "omits_an_empty_template_version" {
  command = plan

  variables {
    project_id              = "stream-test-123"
    region                  = "us-central1"
    stream_api_url          = "https://tenant.streamsec.io"
    stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
    stream_ack_token        = "test-ack-token"
    stream_collection_token = "test-collection-token"
    stream_template_version = ""
  }

  assert {
    condition     = !can(jsondecode(local.stream_ack_payload).template_version)
    error_message = "An empty template version must be omitted from the payload, not sent as an empty string."
  }
}
