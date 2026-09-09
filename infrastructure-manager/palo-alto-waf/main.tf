provider "google" {
  project = var.project_id
  region  = var.region
}

module "palo_alto_waf" {
  source = "../../modules/palo-alto-waf"

  project_id               = var.project_id
  region                   = var.region
  stream_api_url           = var.stream_api_url
  stream_integration_token = var.stream_integration_token
  stream_template_version  = var.stream_template_version
  vpc_network              = var.vpc_network
  subnet                   = var.subnet
  connector_cidr           = var.connector_cidr
  firewall_secret_names    = var.firewall_secret_names
  poll_schedule            = var.poll_schedule
}
