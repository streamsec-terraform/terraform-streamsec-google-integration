mock_provider "archive" {}
mock_provider "google" {}
mock_provider "time" {}

run "acknowledgement_contract" {
  command = plan

  variables {
    project_id               = "stream-test-123"
    region                   = "us-central1"
    stream_api_url           = "https://tenant.streamsec.io/"
    stream_integration_token = "test-token"
    stream_template_version  = "v2.10.0"
    vpc_network              = "test-network"
    subnet                   = "test-subnet"
  }

  assert {
    condition     = local.stream_ack_url == "https://tenant.streamsec.io/api/accounts/waf/waf-acknowledge"
    error_message = "The WAF acknowledgement must use the accounts WAF endpoint without a duplicate slash."
  }

  assert {
    condition     = jsondecode(local.stream_ack_payload) == { template_version = "v2.10.0" }
    error_message = "The WAF acknowledgement payload must contain the deployed template version."
  }

  assert {
    condition     = contains(terraform_data.acknowledge.triggers_replace, "v2.10.0")
    error_message = "Changing the template version must cause Terraform to acknowledge again."
  }
}
