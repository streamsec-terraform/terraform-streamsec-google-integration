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

  # The scanner caps a worker at no more than 11h, and a failed shard gets one
  # retry. Leave room beyond that for discovery and the snapshot sweep.
  assert {
    condition     = try(tonumber(trimsuffix(google_cloud_run_v2_job.orchestrator.template[0].template[0].timeout, "s")), 0) > 22 * 3600
    error_message = "The orchestrator's timeout must cover a shard plus its retry (2 x the scanner's 11h worker cap), with room to spare."
  }

  # The timeout applies to each attempt, so every attempt together must fit in
  # the daily schedule, or one run's orchestrator overlaps the next one.
  assert {
    condition     = (google_cloud_run_v2_job.orchestrator.template[0].template[0].max_retries + 1) * try(tonumber(trimsuffix(google_cloud_run_v2_job.orchestrator.template[0].template[0].timeout, "s")), 86400) < 24 * 3600
    error_message = "All of the orchestrator's attempts must fit in a day, or one run overlaps the next scheduled one."
  }

  # The orchestrator keeps no state between attempts, so a Cloud Run retry
  # rescans every shard, including the ones that already finished. It retries
  # failed shards itself.
  assert {
    condition     = google_cloud_run_v2_job.orchestrator.template[0].template[0].max_retries == 0
    error_message = "Cloud Run must not retry the orchestrator; a retry rescans the whole fleet."
  }
}
