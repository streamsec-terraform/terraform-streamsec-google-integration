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
- **Isolated VPC** with a subnet, router and Cloud NAT in `region` and in each of `worker_regions`, so scan workers run with no external IP
- **Orchestrator Cloud Run Job** on a daily **Cloud Scheduler** trigger; workers are created at runtime as **Batch** jobs
- A post-apply acknowledgement to Stream, best-effort and non-fatal

The orchestrator also gets `COLLECTOR_STREAM_SCAN_TOKEN_SECRET`, the collection token's exact secret version: a resource name, not a secret. Scanner images that read it pass the token to their Batch workers from Secret Manager; older images pass it as a plain job variable, which anyone with the basic Viewer role can read.

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

### Regions

A VM's disk is read only by a Batch worker in the VM's own region, so the module builds a worker subnet, router and Cloud NAT in `region` and in every region of `worker_regions`. The scanner skips VMs in any other region, with a warning that names it. The apply command Stream's console renders lists the regions that have VMs each time it runs, so re-running it covers new ones. Scanner images before v0.5.34 use the subnet in `region` for every worker, so their workers outside `region` still fail to start.

Each extra region adds a Cloud NAT gateway. It is billed per worker VM hour while a scan runs, per GiB it processes (the SBOM uploads to Stream; Google APIs go through Private Google Access), plus any NAT IP it holds.

### Scan feature toggles

| input | default | scanner env |
|---|---|---|
| `scan_language_packages` | `true` (CVEs) | `COLLECTOR_SCAN_LANGUAGE_PACKAGES` |
| `scan_secrets` | `false` | `COLLECTOR_SCAN_SECRETS` |
| `scan_ai_workloads` | `false` | `COLLECTOR_SCAN_AI_WORKLOADS` |
| `scan_data_volumes` | `true` | `COLLECTOR_SCAN_DATA_VOLUMES` |

`scan_data_volumes` scans each VM's attached data disks as well as its boot disk. Each data disk keeps one more scanner snapshot, the next scan's differential base, and a VM with large data disks takes longer to scan. A suffixed instance never scans disks, so it is always off there. An existing deployment picks it up when it is next re-applied.

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

### Projects that restrict resource locations

Under a `constraints/gcp.resourceLocations` org policy, the policy must allow `region`, where Stream's console also creates the Infra Manager deployment, and the region of every VM the scanner scans. Check it with `gcloud org-policies describe constraints/gcp.resourceLocations --project=<PROJECT_ID> --effective`.

- **Secrets:** both are created with one replica in `region`, and stay there if `region` later changes. A deployment created on an older release keeps its secrets' automatic replication, in `global`. Replication can't change in place, so the module leaves it rather than replacing the secrets, and a location policy doesn't apply to resources that already exist.
- **Snapshots:** scanner images v0.5.31 and later store each disk's snapshot in that disk's region. Older images leave the location to the project's snapshot settings, by default the nearest multi-region (`us` for `us-central1`), so a policy without it fails every disk scan while the apply succeeds.

### A second instance in the same project

Every resource name is fixed, so one deployment per project is the default, and a second apply with other inputs takes the scanner over. To run a second scanner beside it, for example one reporting to a staging workspace, give it a `name_suffix` such as `-stg`. Every project-unique name then carries the suffix: the service account, the custom role, the orchestrator job and its scheduler, both secrets, and the network, subnet, router and NAT.

A suffixed instance:

- **Must be workload-only** (`scan_workload_only = "true"`); the plan fails otherwise.
- **Gets no disk or snapshot permissions.** The orchestrator runs a project-wide snapshot sweep after every cycle, workload-only or not. It selects every scanner snapshot in the project, because snapshots are labelled for the scanner, not for an instance. Without those permissions the second instance's sweep fails with a warning instead of deleting the first instance's snapshots.
- **Needs its own deployment**, for example the Infra Manager deployment `streamsec-volume-scanner-stg`. Never add `name_suffix` to an existing deployment: that plans the replacement of every resource of the running scanner.
- **Must report to a different Stream workspace.** Acknowledgements and heartbeats are keyed by project, so two instances reporting to one workspace would interleave its status.
- **Should get a different `scan_schedule`,** so neither instance scans the other's Batch VMs or competes with it for vCPU quota.

### Uninstalling

Delete the Infra Manager deployment. `<LOCATION>` is the `locations/...` part of the command that created it, and may differ from the `region` input:

```bash
gcloud infra-manager deployments delete projects/<PROJECT_ID>/locations/<LOCATION>/deployments/streamsec-volume-scanner
```

A deployment last applied from v2.15.0 or earlier has its orchestrator job deletion-protected in Terraform state, so that delete fails at the job. Re-apply it from a newer release first, or delete the job before the deployment, where `<REGION>` is the `region` input:

```bash
gcloud run jobs delete streamsec-volume-scanner-orchestrator --region=<REGION> --project=<PROJECT_ID>
```

- **An instance with a `name_suffix`** has its own deployment, and its job name ends in the suffix, for example `streamsec-volume-scanner-orchestrator-stg`. Use those names, or you delete the other instance.
- **Delete outside the daily scan.** GCP doesn't delete the scanner's subnet while scan workers still run on it.
- **From your own root,** bump `version` past v2.15.0 and apply before `terraform destroy`.
- **A change that replaces the job,** such as a new `region`, fails the same way on those deployments. Re-apply from a newer release with no other change first.

Then delete the scanner's snapshots. It keeps one per scanned disk as the next scan's base, and Terraform doesn't track them. gcloud lists them and asks before deleting. Skip this when removing only a suffixed instance: it makes none, so these belong to the other instance.

```bash
gcloud compute snapshots delete --project=<PROJECT_ID> \
  $(gcloud compute snapshots list --project=<PROJECT_ID> --filter="labels.purpose=cloud-volume-scanner" --format="value(name)")
```
