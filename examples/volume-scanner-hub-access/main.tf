###############################################################################
# Hub volume scanners' access to the other projects of the organization
#
# Run by an organization admin once the hubs' volume scanners are deployed: the
# role is granted to the service accounts those deployments created.
###############################################################################

# The credentials of the person running this. Every resource names its
# organization, folder or project, so no default project is needed.
provider "google" {}

module "scanner_hub_access" {
  source = "../../modules/volume-scanner-hub-access"

  hub_project_ids = var.hub_project_ids
  org_id          = var.org_id
  create_role     = var.create_role

  # The whole organization by default. To narrow the grant, name folders or
  # projects instead, one of the two:
  # grant_on = { folder_ids = ["111111111111", "222222222222"] }
  # grant_on = { project_ids = ["app-prod-123", "app-staging-456"] }
}
