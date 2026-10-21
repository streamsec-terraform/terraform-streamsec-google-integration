# Stream Security — lets a hub's volume scanner into the other projects of the
# organization (DEV-23499).
#
# The Terraform form of the gcloud command Stream's console renders for a hub,
# for organizations that manage this with their own Terraform. Not wired into
# infrastructure-manager/volume-scanner on purpose: Infra Manager's runner
# service account would then keep org Role Admin and org IAM admin for as long
# as the deployment exists.

locals {
  # Must match lightlytics' _GCP_SCANNER_TARGET_ROLE_ID and
  # _GCP_SCANNER_TARGET_PERMISSIONS (ms_accounts/account_handler.py): the
  # console's command manages this same role, so the two must agree.
  role_id = "streamsecVolumeScannerTarget"
  permissions = [
    # VMs: find them, and snapshot their disks into the hub.
    "compute.instances.list",
    "compute.instances.get",
    "compute.disks.get",
    "compute.disks.createSnapshot",
    # The scanner's access check, which also gives the project number.
    "resourcemanager.projects.get",
    # Workloads: Cloud Run services and jobs, gen1 functions' source, and
    # image pulls.
    "run.locations.list",
    "run.services.list",
    "run.revisions.get",
    "run.jobs.list",
    "cloudfunctions.functions.list",
    "cloudfunctions.functions.sourceCodeGet",
    "artifactregistry.repositories.downloadArtifacts",
  ]

  scanner_sa_email = coalesce(var.scanner_service_account_email, "streamsec-volume-scanner@${var.hub_project_id}.iam.gserviceaccount.com")
  member           = "serviceAccount:${local.scanner_sa_email}"

  scope = var.grant_on.organization ? "organization" : length(var.grant_on.folder_ids) > 0 ? "folders" : "projects"
}

# Read access plus a snapshot of each disk. Snapshots and scan disks live in
# the hub, so everything that creates or deletes stays in the hub's own
# project role (modules/volume-scanner).
resource "google_organization_iam_custom_role" "target" {
  org_id      = var.org_id
  role_id     = local.role_id
  title       = "Stream Security volume scanner: scanned projects"
  stage       = "GA"
  permissions = local.permissions
}

# Non-authoritative members only: the policies they join hold everyone else's
# bindings.
resource "google_organization_iam_member" "target" {
  count  = var.grant_on.organization ? 1 : 0
  org_id = var.org_id
  role   = google_organization_iam_custom_role.target.id
  member = local.member
}

resource "google_folder_iam_member" "target" {
  for_each = toset(var.grant_on.folder_ids)
  folder   = "folders/${each.value}"
  role     = google_organization_iam_custom_role.target.id
  member   = local.member
}

resource "google_project_iam_member" "target" {
  for_each = toset(var.grant_on.project_ids)
  project  = each.value
  role     = google_organization_iam_custom_role.target.id
  member   = local.member
}
