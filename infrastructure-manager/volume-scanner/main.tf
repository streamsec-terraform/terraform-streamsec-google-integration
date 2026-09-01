# Root config Stream Security drives with `gcloud infra-manager deployments
# apply`, targeting this directory with --git-source-directory.
#
# A separate deployment from ../ on purpose: the volume scanner is enabled
# per project, usually long after onboarding, so folding it into the main
# deployment would mean re-applying the whole integration to turn it on.
# Same reason modules/streamforce-plugin is not wired into the root module.
#
# The submodule is referenced by relative path rather than by registry source
# + version, so the git ref Infra Manager clones is the single version of
# record. Pass that same tag as stream_template_version and the post-apply
# acknowledgement reports it back, which is how Stream detects a deployment
# that has fallen behind.

provider "google" {
  project = var.project_id
  region  = var.region
}

module "volume_scanner" {
  source = "../../modules/volume-scanner"

  project_id              = var.project_id
  region                  = var.region
  scanner_image           = var.scanner_image
  stream_api_url          = var.stream_api_url
  stream_customer_id      = var.stream_customer_id
  stream_ack_token        = var.stream_ack_token
  stream_collection_token = var.stream_collection_token
  stream_template_version = var.stream_template_version

  scan_language_packages = var.scan_language_packages
  scan_secrets           = var.scan_secrets
  scan_ai_workloads      = var.scan_ai_workloads
}
