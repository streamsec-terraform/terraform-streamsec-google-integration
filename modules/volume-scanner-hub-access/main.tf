# Stream Security — lets hubs' volume scanners into the other projects of the
# organization.
#
# The Terraform form of the gcloud command Stream's console renders for a hub,
# for organizations that manage this with their own Terraform. Not wired into
# infrastructure-manager/volume-scanner on purpose: Infra Manager's runner
# service account would then keep org Role Admin and org IAM admin for as long
# as the deployment exists.
#
# Every hub of an organization shares the one role, as the console's command
# does, so one instance binds every hub; another instance, or an organization
# whose role the command created, sets create_role = false.

locals {
  # Must match the role Stream's console command manages, its id and its
  # permissions: both manage this same role, so the two must agree.
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

  # Always the literal name, never the role resource's id: a binding's role is
  # ForceNew, so switching create_role either way would otherwise replace every
  # binding. depends_on still orders a created role before its bindings.
  role_name = "organizations/${var.org_id}/roles/${local.role_id}"

  scanner_sa_emails = toset(concat(
    [for id in var.hub_project_ids : "streamsec-volume-scanner@${id}.iam.gserviceaccount.com"],
    tolist(var.scanner_service_account_emails),
  ))

  # Keyed by scope ID and email, so adding or removing a hub, folder or
  # project leaves every other binding where it is.
  folder_bindings = {
    for pair in setproduct(toset(var.grant_on.folder_ids), local.scanner_sa_emails) :
    "${pair[0]}/${pair[1]}" => { folder_id = pair[0], email = pair[1] }
  }
  project_bindings = {
    for pair in setproduct(toset(var.grant_on.project_ids), local.scanner_sa_emails) :
    "${pair[0]}/${pair[1]}" => { project_id = pair[0], email = pair[1] }
  }

  scope = var.grant_on.organization ? "organization" : length(var.grant_on.folder_ids) > 0 ? "folders" : "projects"

  # The hubs' projects. A hub makes each snapshot in its own project, encrypted
  # with the disk's own Cloud KMS key, so the project's Compute Engine service
  # agent needs the keys too.
  hub_projects = toset(concat(
    tolist(var.hub_project_ids),
    [for email in var.scanner_service_account_emails : regex("@([a-z0-9-]+)\\.iam\\.gserviceaccount\\.com$", email)[0]],
  ))
  compute_agents = {
    for id, project in data.google_project.hub :
    id => "serviceAccount:service-${project.number}@compute-system.iam.gserviceaccount.com"
  }
  kms_role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  kms_folder_bindings = {
    for pair in setproduct(toset(var.grant_on.folder_ids), local.hub_projects) :
    "${pair[0]}/${pair[1]}" => { folder_id = pair[0], hub = pair[1] }
  }
  kms_project_bindings = {
    for pair in setproduct(toset(var.grant_on.project_ids), local.hub_projects) :
    "${pair[0]}/${pair[1]}" => { project_id = pair[0], hub = pair[1] }
  }
}

# Its number names the hub project's Compute Engine service agent.
data "google_project" "hub" {
  for_each   = local.hub_projects
  project_id = each.value
}

# Read access plus a snapshot of each disk. Snapshots and scan disks live in
# the hub, so everything that creates or deletes stays in the hub's own
# project role (modules/volume-scanner).
resource "google_organization_iam_custom_role" "target" {
  count       = var.create_role ? 1 : 0
  org_id      = var.org_id
  role_id     = local.role_id
  title       = "Stream Security volume scanner: scanned projects"
  stage       = "GA"
  permissions = local.permissions
}

# Non-authoritative members only: the policies they join hold everyone else's
# bindings.
resource "google_organization_iam_member" "target" {
  for_each = var.grant_on.organization ? local.scanner_sa_emails : toset([])
  org_id   = var.org_id
  role     = local.role_name
  member   = "serviceAccount:${each.value}"

  depends_on = [google_organization_iam_custom_role.target]
}

resource "google_folder_iam_member" "target" {
  for_each = local.folder_bindings
  folder   = "folders/${each.value.folder_id}"
  role     = local.role_name
  member   = "serviceAccount:${each.value.email}"

  depends_on = [google_organization_iam_custom_role.target]
}

resource "google_project_iam_member" "target" {
  for_each = local.project_bindings
  project  = each.value.project_id
  role     = local.role_name
  member   = "serviceAccount:${each.value.email}"

  depends_on = [google_organization_iam_custom_role.target]
}

# The keys of disks the hubs snapshot, on the same scope as the role. GCP has
# no condition that limits a key grant to Compute Engine, so this covers every
# key there; the service agent uses them only for Compute Engine operations in
# its hub, which still need the role above on the disk. Keys outside the scope,
# such as in a central key project, need their own grant.
resource "google_organization_iam_member" "kms" {
  for_each = var.grant_on.organization ? local.hub_projects : toset([])
  org_id   = var.org_id
  role     = local.kms_role
  member   = local.compute_agents[each.value]
}

resource "google_folder_iam_member" "kms" {
  for_each = local.kms_folder_bindings
  folder   = "folders/${each.value.folder_id}"
  role     = local.kms_role
  member   = local.compute_agents[each.value.hub]
}

resource "google_project_iam_member" "kms" {
  for_each = local.kms_project_bindings
  project  = each.value.project_id
  role     = local.kms_role
  member   = local.compute_agents[each.value.hub]
}
