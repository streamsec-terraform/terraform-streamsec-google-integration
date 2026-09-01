# State migration for deployments created before the scanner became a module.
#
# The Infra Manager deployment id is unchanged (streamsec-volume-scanner), so
# retargeting an existing deployment at this root REUSES its Terraform state.
# Every resource in that state sits at a ROOT address
# (google_service_account.scanner); wrapping the config in a module moves them
# all to module.volume_scanner.*.
#
# Without these blocks the first apply reads the old addresses as deleted and
# the new ones as created, destroying and recreating fixed-name resources: the
# service account, the custom role (soft-deleted, so the id cannot be reused
# straight away), both secrets, the VPC. Some fail outright on name conflict,
# and a scan in flight loses its snapshots.
#
# One block per resource, including the for_each'''d API resource - moving a
# resource moves all of its instances.

moved {
  from = google_project_service.apis
  to   = module.volume_scanner.google_project_service.apis
}

moved {
  from = google_service_account.scanner
  to   = module.volume_scanner.google_service_account.scanner
}

moved {
  from = google_project_iam_custom_role.scanner
  to   = module.volume_scanner.google_project_iam_custom_role.scanner
}

moved {
  from = google_project_iam_member.scanner
  to   = module.volume_scanner.google_project_iam_member.scanner
}

moved {
  from = google_project_iam_member.scanner_agent_reporter
  to   = module.volume_scanner.google_project_iam_member.scanner_agent_reporter
}

moved {
  from = google_secret_manager_secret.collection_token
  to   = module.volume_scanner.google_secret_manager_secret.collection_token
}

moved {
  from = google_secret_manager_secret_version.collection_token
  to   = module.volume_scanner.google_secret_manager_secret_version.collection_token
}

moved {
  from = google_secret_manager_secret.ack_token
  to   = module.volume_scanner.google_secret_manager_secret.ack_token
}

moved {
  from = google_secret_manager_secret_version.ack_token
  to   = module.volume_scanner.google_secret_manager_secret_version.ack_token
}

moved {
  from = google_secret_manager_secret_iam_member.collection_token_accessor
  to   = module.volume_scanner.google_secret_manager_secret_iam_member.collection_token_accessor
}

moved {
  from = google_secret_manager_secret_iam_member.ack_token_accessor
  to   = module.volume_scanner.google_secret_manager_secret_iam_member.ack_token_accessor
}

moved {
  from = google_compute_network.scanner
  to   = module.volume_scanner.google_compute_network.scanner
}

moved {
  from = google_compute_subnetwork.scanner
  to   = module.volume_scanner.google_compute_subnetwork.scanner
}

moved {
  from = google_compute_router.scanner
  to   = module.volume_scanner.google_compute_router.scanner
}

moved {
  from = google_compute_router_nat.scanner
  to   = module.volume_scanner.google_compute_router_nat.scanner
}

moved {
  from = google_cloud_run_v2_job.orchestrator
  to   = module.volume_scanner.google_cloud_run_v2_job.orchestrator
}

moved {
  from = google_cloud_scheduler_job.cron
  to   = module.volume_scanner.google_cloud_scheduler_job.cron
}

moved {
  from = terraform_data.acknowledge
  to   = module.volume_scanner.terraform_data.acknowledge
}
