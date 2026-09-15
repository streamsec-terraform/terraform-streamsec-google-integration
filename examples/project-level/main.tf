###############################################################################
# Project-level integration (no organization permissions required)
#
# Use this when the person running Terraform only has access to a single GCP
# project and cannot be granted anything at the organization.
#
# Trade-offs vs. the org-level integration:
#   - Only the listed project is integrated. Run this per project to cover more.
#   - Organization- and folder-level IAM bindings and org policies are not
#     collected, so permissions a principal inherits from above the project
#     are not visible.
###############################################################################

provider "google" {
  project = "my-gcp-project" # the project being integrated
  region  = "us-central1"    # required: Cloud Function + regional secret location
}

provider "streamsec" {
  host         = "xxxxx.streamsec.io" # required
  workspace_id = "xxxxxxxxxxxx"       # required
  api_token    = "xxxxxxxxxxxx"       # required unless username and password are set
}

# Required even when enable_vertex_ai_logging is false: the module declares the
# Mastercard `restapi` provider and it needs a `uri` to load. See
# modules/vertex-ai-logging/README.md for the full configuration when enabling it.
provider "restapi" {
  uri = "https://us-central1-aiplatform.googleapis.com"
}

module "streamsec_google_projects" {
  source = "../../"

  #############################################################################
  # Project-level permissions
  #############################################################################

  # Required in this mode: there is no org-wide project discovery to fall back
  # on, so the projects to integrate must be listed explicitly.
  include_projects = ["my-gcp-project"]

  # Grants roles/viewer + roles/iam.securityReviewer to the Stream Security
  # service account on each project above, instead of on the organization.
  sa_project_level_permissions = true

  # org_id is deliberately not set. It is only needed for org-level IAM
  # bindings, the org log sink, and the org-scoped project discovery, none of
  # which run in this mode.

  create_sa      = true
  project_for_sa = "my-gcp-project"

  #############################################################################
  # Real-time events
  #
  # Must be per-project: an org-level sink requires org_id and organization
  # permissions. This creates a Pub/Sub topic, project log sink, secret and
  # Cloud Function in each integrated project.
  #############################################################################

  enable_real_time_events = true
  org_level_sink          = false
  use_secret_manager      = true
  regional_secret         = true

  #############################################################################
  # Response (optional)
  #
  # Works without org permissions only with project-level permissions set.
  #############################################################################

  # response_enabled_projects      = ["my-gcp-project"]
  # response_org_level_permissions = false
  # region                         = "us-central1"
}
