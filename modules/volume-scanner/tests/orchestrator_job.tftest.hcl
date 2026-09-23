mock_provider "google" {}

# With neither timeout nor max_retries set, Cloud Run runs the orchestrator on
# its defaults: 600s per attempt and 3 retries. The orchestrator waits for its
# Batch workers, which take longer than that, so every scheduled run was killed
# mid-wait and each retry rescanned the whole fleet from scratch (DEV-22980).
run "orchestrator_outlives_its_workers" {
  command = plan

  variables {
    project_id              = "stream-test-123"
    region                  = "us-central1"
    stream_api_url          = "https://tenant.streamsec.io"
    stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
    stream_ack_token        = "test-ack-token"
    stream_collection_token = "test-collection-token"
  }

  # The scanner caps a worker at 11h, and a failed shard gets one retry.
  assert {
    condition     = try(tonumber(trimsuffix(google_cloud_run_v2_job.orchestrator.template[0].template[0].timeout, "s")), 0) >= 22 * 3600
    error_message = "The orchestrator's timeout must cover one shard plus its retry (2 x the scanner's 11h worker cap)."
  }

  # The cron fires daily; a run that outlives a day overlaps the next one and
  # snapshots the same disks twice.
  assert {
    condition     = try(tonumber(trimsuffix(google_cloud_run_v2_job.orchestrator.template[0].template[0].timeout, "s")), 86400) < 24 * 3600
    error_message = "The orchestrator's timeout must stay under the daily schedule so runs never overlap."
  }

  # The orchestrator keeps no state between attempts, so a Cloud Run retry
  # rescans every shard, including the ones that already finished. It retries
  # failed shards itself.
  assert {
    condition     = google_cloud_run_v2_job.orchestrator.template[0].template[0].max_retries == 0
    error_message = "Cloud Run must not retry the orchestrator; a retry rescans the whole fleet."
  }
}
