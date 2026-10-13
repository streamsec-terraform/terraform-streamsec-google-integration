mock_provider "google" {}

variables {
  project_id              = "stream-test-123"
  region                  = "us-central1"
  stream_api_url          = "https://tenant.streamsec.io"
  stream_customer_id      = "66fb95548de1fcbdf0ca10e5"
  stream_ack_token        = "test-ack-token"
  stream_collection_token = "test-collection-token"
}

# Unset, the deployment is what it was before: one subnet, in region.
run "defaults_to_the_install_region_alone" {
  command = plan

  assert {
    condition     = length(google_compute_subnetwork.regional) == 0 && length(google_compute_router_nat.regional) == 0
    error_message = "Without worker_regions no regional network may be planned."
  }
  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_GCP_WORKER_SUBNETWORKS"]) == "projects/stream-test-123/regions/us-central1/subnetworks/streamsec-scanner-subnet"
    error_message = "COLLECTOR_GCP_WORKER_SUBNETWORKS must name the install region's subnet."
  }
}

run "normalises_the_region_list" {
  command = plan

  variables {
    worker_regions = " europe-west1, US-CENTRAL1,asia-east1,europe-west1 ,"
  }

  assert {
    condition     = join(",", keys(google_compute_subnetwork.regional)) == "asia-east1,europe-west1"
    error_message = "worker_regions must be trimmed, lowercased and deduplicated, without the install region."
  }
  assert {
    condition = (
      google_compute_subnetwork.regional["europe-west1"].name == "streamsec-scanner-subnet-europe-west1"
      && google_compute_subnetwork.regional["europe-west1"].region == "europe-west1"
      && google_compute_subnetwork.regional["europe-west1"].private_ip_google_access
      && google_compute_router.regional["europe-west1"].name == "streamsec-scanner-router-europe-west1"
      && google_compute_router_nat.regional["europe-west1"].name == "streamsec-scanner-nat-europe-west1"
      && google_compute_router_nat.regional["europe-west1"].region == "europe-west1"
    )
    error_message = "Each region needs its own subnet, router and NAT, named for the region."
  }
  assert {
    condition = (
      google_compute_subnetwork.regional["europe-west1"].ip_cidr_range == "10.20.250.0/24"
      && google_compute_subnetwork.regional["asia-east1"].ip_cidr_range == "10.22.247.0/24"
      && google_compute_subnetwork.scanner.ip_cidr_range == "10.61.0.0/24"
    )
    error_message = "Each region's range comes from a hash of its name; the install region keeps 10.61.0.0/24."
  }
  assert {
    condition     = one([for e in google_cloud_run_v2_job.orchestrator.template[0].template[0].containers[0].env : e.value if e.name == "COLLECTOR_GCP_WORKER_SUBNETWORKS"]) == "projects/stream-test-123/regions/us-central1/subnetworks/streamsec-scanner-subnet,projects/stream-test-123/regions/asia-east1/subnetworks/streamsec-scanner-subnet-asia-east1,projects/stream-test-123/regions/europe-west1/subnetworks/streamsec-scanner-subnet-europe-west1"
    error_message = "COLLECTOR_GCP_WORKER_SUBNETWORKS must list every worker subnet, install region first."
  }
}

# A re-apply with one more region must not move a live subnet's range.
run "a_regions_range_does_not_depend_on_the_others" {
  command = plan

  variables {
    worker_regions = "europe-west1"
  }

  assert {
    condition     = google_compute_subnetwork.regional["europe-west1"].ip_cidr_range == "10.20.250.0/24"
    error_message = "europe-west1's range must not depend on which other regions are listed."
  }
}

# Every Compute region at 2026-10-13: no two share a range, none is 10.61.0.0/24.
run "every_current_region_gets_its_own_range" {
  command = plan

  variables {
    worker_regions = "africa-south1,asia-east1,asia-east2,asia-northeast1,asia-northeast2,asia-northeast3,asia-south1,asia-south2,asia-southeast1,asia-southeast2,asia-southeast3,australia-southeast1,australia-southeast2,europe-central2,europe-north1,europe-north2,europe-southwest1,europe-west1,europe-west10,europe-west12,europe-west2,europe-west3,europe-west4,europe-west6,europe-west8,europe-west9,me-central1,me-central2,me-west1,northamerica-northeast1,northamerica-northeast2,northamerica-south1,southamerica-east1,southamerica-west1,us-central1,us-east1,us-east4,us-east5,us-south1,us-west1,us-west2,us-west3,us-west4"
  }

  assert {
    condition     = length(google_compute_subnetwork.regional) == 42
    error_message = "Every region but the install region needs a subnet."
  }
}

run "colliding_ranges_are_rejected" {
  command = plan

  variables {
    worker_regions = "zza-testaa8,zza-testbk4"
  }

  expect_failures = [google_compute_subnetwork.regional]
}

run "a_range_on_the_install_subnet_is_rejected" {
  command = plan

  variables {
    worker_regions = "zzc-testsg6"
  }

  expect_failures = [google_compute_subnetwork.regional]
}

# A workload-only instance never reads a disk, so needs no regional workers.
run "workload_only_ignores_worker_regions" {
  command = plan

  variables {
    worker_regions     = "europe-west1"
    scan_workload_only = "true"
  }

  assert {
    condition     = length(google_compute_subnetwork.regional) == 0
    error_message = "A workload-only instance must not build regional networks."
  }
}

run "rejects_a_malformed_region" {
  command = plan

  variables {
    worker_regions = "europe_west1"
  }

  expect_failures = [var.worker_regions]
}
