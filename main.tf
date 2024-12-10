
resource "streamsec_gcp_project" "this" {
  for_each     = { for k, v in var.projects : k => v }
  display_name = each.key
  project_id   = each.value.project_id
}

resource "google_service_account" "this" {
  for_each     = var.org_level_permissions ? { "org" = { project_id = var.project_for_sa } } : { for k, v in var.projects : k => v }
  account_id   = try(each.value.sa_account_id, var.sa_account_id)
  display_name = try(each.value.sa_display_name, var.sa_display_name)
  description  = try(each.value.sa_description, var.sa_description)
  project      = each.value.project_id
}

# create service account key for each service account
resource "google_service_account_key" "this" {
  for_each           = google_service_account.this
  service_account_id = each.value.id
}

resource "google_organization_iam_member" "this" {
  count  = var.org_level_permissions ? 1 : 0
  role   = "roles/viewer"
  member = "serviceAccount:${google_service_account.this["org"].email}"
  org_id = var.org_id
}

resource "google_organization_iam_member" "security_reviewer" {
  count  = var.org_level_permissions ? 1 : 0
  role   = "roles/iam.securityReviewer"
  member = "serviceAccount:${google_service_account.this["org"].email}"
  org_id = var.org_id
}

# assign viewer role to service account
resource "google_project_iam_member" "this" {
  for_each = var.org_level_permissions ? {} : google_service_account.this
  role     = "roles/viewer"
  member   = "serviceAccount:${each.value.email}"
  project  = each.value.project
}

# assign roles/iam.securityReviewer
resource "google_project_iam_member" "security_reviewer" {
  for_each = var.org_level_permissions ? {} : google_service_account.this
  role     = "roles/iam.securityReviewer"
  member   = "serviceAccount:${each.value.email}"
  project  = each.value.project
}

resource "streamsec_gcp_project_ack" "this" {
  for_each     = { for k, v in var.projects : k => v }
  project_id   = each.value.project_id
  client_email = var.org_level_permissions ? google_service_account.this["org"].email : google_service_account.this[each.key].email
  private_key  = var.org_level_permissions ? jsondecode(base64decode(google_service_account_key.this["org"].private_key)).private_key : jsondecode(base64decode(google_service_account_key.this[each.key].private_key)).private_key

  depends_on = [google_organization_iam_member.this, google_organization_iam_member.security_reviewer, google_project_iam_member.this, google_project_iam_member.security_reviewer]
}


module "real_time_events" {
  count      = var.enable_real_time_events ? 1 : 0
  source     = "./modules/real-time-events"
  projects   = var.projects
  depends_on = [streamsec_gcp_project_ack.this]
}

module "flowlogs" {
  count      = length([for k, v in var.projects : 1 if contains(keys(v), "flowlogs_bucket_name")])
  source     = "./modules/flowlogs"
  projects   = var.projects
  depends_on = [streamsec_gcp_project_ack.this]
}
