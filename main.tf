# if var.org_integration is true, find all of the projects in the organization and add them to the var.projects map
data "google_projects" "this" {
  count  = var.org_integration ? 1 : 0
  filter = "name:*"
}

locals {
  projects = var.org_integration ? { for p in data.google_projects.this[0].projects : p.project_id => p if(!contains(var.exclude_projects, p.project_id) && (length(var.include_projects) > 0 ? contains(var.include_projects, p.project_id) : true)) } : var.projects
}

resource "streamsec_gcp_project" "this" {
  for_each     = { for k, v in local.projects : k => v }
  display_name = each.value.name
  project_id   = each.value.project_id
}

resource "google_service_account" "org" {
  count        = var.create_sa && var.org_integration ? 1 : 0
  account_id   = var.sa_account_id
  display_name = var.sa_display_name
  description  = var.sa_description
  project      = var.project_for_sa
}

resource "google_service_account" "project" {
  for_each     = var.create_sa && !var.org_integration ? local.projects : {}
  account_id   = try(each.value.sa_account_id, var.sa_account_id)
  display_name = try(each.value.sa_display_name, var.sa_display_name)
  description  = try(each.value.sa_description, var.sa_description)
  project      = each.value.project_id
}

# create service account key for each service account
resource "google_service_account_key" "org" {
  count              = var.create_sa && var.org_integration ? 1 : 0
  service_account_id = google_service_account.org[0].id
}


resource "google_service_account_key" "project" {
  for_each           = var.create_sa && !var.org_integration ? local.projects : {}
  service_account_id = google_service_account.project[each.key].id
}

resource "google_organization_iam_member" "this" {
  count  = var.org_integration && var.create_sa ? 1 : 0
  role   = "roles/viewer"
  member = "serviceAccount:${google_service_account.org[0].email}"
  org_id = var.org_id
}

resource "google_organization_iam_member" "security_reviewer" {
  count  = var.org_integration && var.create_sa ? 1 : 0
  role   = "roles/iam.securityReviewer"
  member = "serviceAccount:${google_service_account.org[0].email}"
  org_id = var.org_id
}

# assign viewer role to service account
resource "google_project_iam_member" "this" {
  for_each = var.create_sa ? (var.org_integration ? {} : google_service_account.project) : {}
  role     = "roles/viewer"
  member   = "serviceAccount:${each.value.email}"
  project  = each.value.project
}

# assign roles/iam.securityReviewer
resource "google_project_iam_member" "security_reviewer" {
  for_each = var.create_sa ? (var.org_integration ? {} : google_service_account.project) : {}
  role     = "roles/iam.securityReviewer"
  member   = "serviceAccount:${each.value.email}"
  project  = each.value.project
}

# add sleep to wait for the service account to be created
resource "time_sleep" "this" {
  create_duration = "10s"
  depends_on      = [streamsec_gcp_project.this]
}

resource "streamsec_gcp_project_ack" "this" {
  for_each     = { for k, v in local.projects : k => v }
  project_id   = each.value.project_id
  client_email = var.create_sa ? (var.org_integration ? google_service_account.org[0].email : google_service_account.project[each.key].email) : jsondecode(file(var.existing_sa_json_file_path)).client_email
  private_key  = var.create_sa ? (var.org_integration ? jsondecode(base64decode(google_service_account_key.org[0].private_key)).private_key : jsondecode(base64decode(google_service_account_key.project[each.key].private_key)).private_key) : jsondecode(file(var.existing_sa_json_file_path)).private_key

  depends_on = [google_organization_iam_member.this, google_organization_iam_member.security_reviewer, google_project_iam_member.this, google_project_iam_member.security_reviewer, time_sleep.this]
}


module "real_time_events" {
  count      = var.enable_real_time_events ? 1 : 0
  source     = "./modules/real-time-events"
  projects   = local.projects
  depends_on = [streamsec_gcp_project_ack.this]
}

module "flowlogs" {
  count      = length([for k, v in local.projects : 1 if contains(keys(v), "flowlogs_bucket_name")])
  source     = "./modules/flowlogs"
  projects   = local.projects
  depends_on = [streamsec_gcp_project_ack.this]
}
