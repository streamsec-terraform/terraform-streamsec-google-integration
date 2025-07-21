# if var.org_integration is true, find all of the projects in the organization and add them to the var.projects map
data "google_projects" "this" {
  filter = var.projects_filter
}

locals {
  projects = { for p in data.google_projects.this.projects : p.project_id => p if(!contains(var.exclude_projects, p.project_id) && (length(var.include_projects) > 0 ? contains(var.include_projects, p.project_id) : true)) }
}

resource "streamsec_gcp_project" "this" {
  for_each     = { for k, v in local.projects : k => v }
  display_name = each.value.name
  project_id   = each.value.project_id
}

resource "google_service_account" "org" {
  count        = var.create_sa ? 1 : 0
  account_id   = var.sa_account_id
  display_name = var.sa_display_name
  description  = var.sa_description
  project      = var.project_for_sa
}

data "google_service_account" "existing" {
  count      = !var.create_sa && var.existing_sa_json_file_path == null ? 1 : 0
  account_id = var.sa_account_id
  project    = var.project_for_sa
}

# create service account key for each service account
resource "google_service_account_key" "org" {
  count              = var.existing_sa_json_file_path == null ? 1 : 0
  service_account_id = var.create_sa ? google_service_account.org[0].id : data.google_service_account.existing[0].id
}

resource "google_organization_iam_member" "this" {
  count  = var.create_sa ? 1 : 0
  role   = "roles/viewer"
  member = "serviceAccount:${google_service_account.org[0].email}"
  org_id = var.org_id
}

resource "google_organization_iam_member" "security_reviewer" {
  count  = var.create_sa ? 1 : 0
  role   = "roles/iam.securityReviewer"
  member = "serviceAccount:${google_service_account.org[0].email}"
  org_id = var.org_id
}
# add sleep to wait for the service account to be created
resource "time_sleep" "this" {
  for_each        = { for k, v in local.projects : k => v }
  create_duration = "10s"
  depends_on      = [streamsec_gcp_project.this]
}

resource "streamsec_gcp_project_ack" "this" {
  for_each     = { for k, v in local.projects : k => v }
  project_id   = each.value.project_id
  client_email = var.create_sa ? google_service_account.org[0].email : var.existing_sa_json_file_path == null ? data.google_service_account.existing[0].email : jsondecode(file(var.existing_sa_json_file_path)).client_email
  private_key  = var.create_sa ? jsondecode(base64decode(google_service_account_key.org[0].private_key)).private_key : var.existing_sa_json_file_path == null ? jsondecode(base64decode(google_service_account_key.org[0].private_key)).private_key : jsondecode(file(var.existing_sa_json_file_path)).private_key

  depends_on = [google_organization_iam_member.this, google_organization_iam_member.security_reviewer, time_sleep.this]
}


module "real_time_events" {
  count                 = var.enable_real_time_events ? 1 : 0
  source                = "./modules/real-time-events"
  projects              = local.projects
  use_secret_manager    = var.use_secret_manager
  secret_name           = var.secret_name
  org_level_sink        = var.org_level_sink
  organization_id       = var.org_id
  project_for_resources = var.project_for_resources
  log_sink_filter       = var.log_sink_filter
  depends_on            = [streamsec_gcp_project_ack.this]
}

module "flowlogs" {
  count      = length([for k, v in local.projects : 1 if contains(keys(v), "flowlogs_bucket_name")])
  source     = "./modules/flowlogs"
  projects   = local.projects
  depends_on = [streamsec_gcp_project_ack.this]
}
