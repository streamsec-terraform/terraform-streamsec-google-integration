# there is a map of projects with project_id and display name
# create service account for each project

resource "streamsec_gcp_project" "this" {
  for_each     = { for k, v in var.projects : k => v }
  display_name = each.key
  project_id   = each.value.project_id
}

resource "google_service_account" "this" {
  for_each     = { for k, v in var.projects : k => v }
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

# assign viewer role to service account
resource "google_project_iam_member" "this" {
  for_each = google_service_account.this
  role     = "roles/viewer"
  member   = "serviceAccount:${each.value.email}"
  project  = each.value.project
}

# assign roles/iam.securityReviewer
resource "google_project_iam_member" "security_reviewer" {
  for_each = google_service_account.this
  role     = "roles/iam.securityReviewer"
  member   = "serviceAccount:${each.value.email}"
  project  = each.value.project
}

resource "streamsec_gcp_project_ack" "this" {
  for_each     = google_service_account.this
  project_id   = each.value.project
  client_email = each.value.email
  private_key  = jsondecode(base64decode(google_service_account_key.this[each.key].private_key)).private_key

  depends_on = [streamsec_gcp_project.this]
}
