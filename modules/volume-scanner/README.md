## Stream Security agentless volume scanner (GCP)

Agentless vulnerability scanning of Compute Engine disks. The scanner runs
**inside your project**, snapshots disks, extracts SBOMs and ships them to
Stream Security for CVE matching. No agent is installed on any instance, and
Stream is granted no inbound credentials — every callback is outbound, and
authenticated by tokens minted for this deployment.

### What this module creates

- **Required APIs** enabled in the target project (Compute, Batch, Cloud Run, Cloud Scheduler, Secret Manager)
- **Service account** shared by the orchestrator and its workers
- **Least-privilege custom role** — discover VMs, snapshot/attach disks, run Batch workers, plus read access for each workload kind left on (see [Workload scanning](#workload-scanning)); no data-plane read beyond the disks and workloads it scans
- **Secret Manager secrets** for the collection and acknowledge tokens, so neither is a plaintext Cloud Run env var
- **Isolated VPC + Cloud NAT**, so scan workers run with no external IP
- **Orchestrator Cloud Run Job** on a daily **Cloud Scheduler** trigger; workers are created at runtime as **Batch** jobs
- A post-apply acknowledgement to Stream, best-effort and non-fatal

### Usage

```hcl
module "volume_scanner" {
  source  = "streamsec-terraform/google-integration/streamsec//modules/volume-scanner"
  version = "~> 2.9"

  project_id              = "my-project"
  region                  = "us-central1"
  scanner_image           = "us-docker.pkg.dev/stream-secops-project/streamsec-public/volume-scanner:latest"
  stream_api_url          = "https://<tenant>.streamsec.io"
  stream_customer_id      = "<workspace id>"
  stream_ack_token        = "<from the Stream console>"
  stream_collection_token = "<from the Stream console>"
}
```

Every value above is filled in for you by the Stream console — Integrations →
Vulnerability Scanners → deploy for your project — which renders the whole
command ready to paste into Cloud Shell.

### Deployed by Stream, or by you

Stream drives this through **Infrastructure Manager**, applying
`infrastructure-manager/volume-scanner` from a release tag of this repo. That
root is a thin wrapper around this module and exists because Infra Manager
applies a Terraform *root*, not a module.

If you manage Stream as code, call this module from your own root instead and
pin `version` — then the scanner updates when you bump the pin, like every
other submodule here.

### The install acknowledgement runs on your Terraform runner

The module posts an install acknowledgement to Stream through a `local-exec`
provisioner, so it runs wherever `terraform apply` runs — **not** inside GCP.
It needs `curl` and outbound access to your Stream API host. On a runner that
has neither (some CI images, or a network without egress to it), the call fails
and is swallowed deliberately: it must never fail your apply.

Nothing is lost when that happens. The orchestrator carries the same
credentials and acknowledges on its first run, so the deployment shows as
*pending* in the console until the first scheduled scan rather than never
registering at all.

### Versions and updates

`stream_template_version` is echoed back in the install acknowledgement so the
Stream console can tell you when a deployment has fallen behind the current
module. Pass the release tag you pinned. Leaving it empty records the
deployment's version as *unknown* rather than as a version it does not have.

### Scan feature toggles

| input | default | scanner env |
|---|---|---|
| `scan_language_packages` | `true` (CVEs) | `COLLECTOR_SCAN_LANGUAGE_PACKAGES` |
| `scan_secrets` | `false` | `COLLECTOR_SCAN_SECRETS` |
| `scan_ai_workloads` | `false` | `COLLECTOR_SCAN_AI_WORKLOADS` |

### Workload scanning

Besides VM disks, the scanner scans the images of the project's serverless workloads. Each kind has its own toggle, and its permissions are granted only while it is on.

| input | default | scans | permissions it adds |
|---|---|---|---|
| `scan_cloud_run` | `true` | Cloud Run services, including Cloud Run functions and gen2 Cloud Functions: the image of every revision serving traffic | `run.locations.list`, `run.services.list`, `run.revisions.get`, `artifactregistry.repositories.downloadArtifacts` |
| `scan_cloud_run_jobs` | `true` | Cloud Run jobs | `run.locations.list`, `run.jobs.list`, `artifactregistry.repositories.downloadArtifacts` |
| `scan_cloud_functions` | `true` | gen1 Cloud Functions, from their deployed source | `cloudfunctions.functions.list`, `cloudfunctions.functions.sourceCodeGet` |
| `scan_workload_only` | `false` | only the kinds above, no VM disks; needs at least one of them on | none |

They reach the scanner as `COLLECTOR_WORKLOAD_KINDS` (`none` when every kind is off) and `COLLECTOR_WORKLOAD_ONLY`. An image in another project's Artifact Registry also needs `roles/artifactregistry.reader` for the scanner's service account in that project.

What the workload permissions reach, so you can decide which kinds to leave on:

- They are all read-only and all within the basic Viewer role. `cloudfunctions.functions.sourceCodeGet` reads every function's deployed source, and listing services, jobs and functions returns their specs, plain environment variables included. The scanner uses only names, images and source, and uploads only package inventories.
- `artifactregistry.repositories.downloadArtifacts` is granted on the project, so it covers every repository and format in it, remote repositories included. IAM can't narrow it by format.
- Images still in legacy Container Registry storage, never migrated to Artifact Registry, also need `storage.objects.get` on `artifacts.<project>.appspot.com`. Without it those images fail to pull, and the rest of the scan continues.
- The workload scan runs as one Batch job in `region`, pulling images and source from every region of the project into that one.
- Re-applying a deployment from an older release turns the three kinds on, since they default to `true`. Set them to `false` first if you don't want that access.
- `scan_workload_only` skips the disk scan but keeps its permissions for now, since the snapshot sweep still runs in that mode.
- The kinds need a scanner image with GCP workload scanning, newer than v0.5.21. Older images ignore them, and with `scan_workload_only` an older image scans nothing.

### A second instance in the same project

Every resource name is fixed, so one deployment per project is the default, and a second apply with other inputs takes the scanner over. To run a second scanner beside it, for example one reporting to a staging workspace, give it a `name_suffix` such as `-stg`. Every project-unique name then carries the suffix: the service account, the custom role, the orchestrator job and its scheduler, both secrets, and the network, subnet, router and NAT.

A suffixed instance must be workload-only (`scan_workload_only = "true"`), and the plan fails otherwise. Disk-scanning snapshots are labelled for the scanner, not for an instance, so a second disk scanner would delete the first one's snapshots and break its incremental bases. Workload scanning only lists workloads and pulls their images and source, so two instances don't interfere.
