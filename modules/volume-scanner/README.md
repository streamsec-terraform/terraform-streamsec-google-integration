## Stream Security agentless volume scanner (GCP)

Agentless vulnerability scanning of Compute Engine disks. The scanner runs
**inside your project**, snapshots disks, extracts SBOMs and ships them to
Stream Security for CVE matching. No agent is installed on any instance, and
Stream is granted no inbound credentials — every callback is outbound, and
authenticated by tokens minted for this deployment.

### What this module creates

- **Required APIs** enabled in the target project (Compute, Batch, Cloud Run, Cloud Scheduler, Secret Manager, Resource Manager). A scanner that also scans other projects of the organization reads each one with Resource Manager, which counts the call against the scanner's own project, so the API must be enabled there; see [Scanning other projects](#scanning-other-projects-hub)
- **Service account** shared by the orchestrator and its workers
- **Least-privilege custom role** — discover VMs, snapshot/attach disks, run Batch workers, plus read access for each workload kind left on (see [Workload scanning](#workload-scanning)); no data-plane read beyond the disks and workloads it scans
- **Secret Manager secrets** for the collection and acknowledge tokens, so neither is a plaintext Cloud Run env var
- **Isolated VPC** with a subnet, router and Cloud NAT in `region` and in each of `worker_regions`, so scan workers run with no external IP
- **Orchestrator Cloud Run Job** on a daily **Cloud Scheduler** trigger; workers are created at runtime as **Batch** jobs
- A post-apply acknowledgement to Stream, best-effort and non-fatal
- One scan started at install, so the first doesn't wait for the schedule; best-effort and non-fatal (see below)

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

### The install acknowledgement and first scan run on your Terraform runner

The module posts an install acknowledgement to Stream through a `local-exec`
provisioner, so it runs wherever `terraform apply` runs — **not** inside GCP.
It needs `curl` and outbound access to your Stream API host. On a runner that
has neither (some CI images, or a network without egress to it), the call fails
and is swallowed deliberately: it must never fail your apply.

Nothing is lost when that happens. The orchestrator carries the same
credentials and acknowledges on its first run, so the deployment shows as
*pending* in the console until its first scan rather than never registering at
all.

The first scan is started the same way, once per orchestrator job, so a new
install scans right away and a re-apply doesn't scan again. It waits three
minutes for the scanner's IAM grants to take effect, then calls the Cloud Run API
(`run.googleapis.com`) with the runner's own Google credentials, which need
`run.jobs.get` and `run.jobs.run` on the job. It doesn't start a run while one
is in progress. If it can't start one, the first scan runs on `scan_schedule`.
An existing install updated to this version scans once at that update.

- **Its output is hidden,** since it carries the runner's access token, which
  Terraform treats as sensitive. To see whether it started, run
  `gcloud run jobs executions list --job=streamsec-volume-scanner-orchestrator<NAME_SUFFIX> --region=<REGION> --project=<PROJECT_ID>`,
  where `<NAME_SUFFIX>` is the `name_suffix` input, empty by default.
- **The token is kept in the Terraform state** with the data source that reads
  it, as any use of `google_client_config` keeps it. It expires within an hour.
- **An install shortly before `scan_schedule`** can overlap that night's
  scheduled run once, since the schedule doesn't wait for the first scan.

### Versions and updates

`stream_template_version` is echoed back in the install acknowledgement so the
Stream console can tell you when a deployment has fallen behind the current
module. Pass the release tag you pinned. Leaving it empty records the
deployment's version as *unknown* rather than as a version it does not have.

### Regions

A VM's disk is read only by a Batch worker in the VM's own region, so the module builds a worker subnet, router and Cloud NAT in `region` and in every region of `worker_regions`. The scanner skips VMs in any other region, with a warning that names it. The apply command Stream's console renders lists the regions that have VMs each time it runs, so re-running it covers new ones. Scanner images before v0.5.34 use the subnet in `region` for every worker, so their workers outside `region` still fail to start.

Each extra region adds a Cloud NAT gateway. It is billed per worker VM hour while a scan runs, per GiB it processes (the SBOM uploads to Stream; Google APIs and registries, `mirror.gcr.io` included, go through Private Google Access), plus any NAT IP it holds. The NAT in `region` also carries the workload scan's image pulls from registries outside Google, such as Docker Hub when `mirror.gcr.io` lacks an image, `quay.io` or `ghcr.io`, most of which `scan_gke_images` adds.

### Scan feature toggles

| input | default | scanner env |
|---|---|---|
| `scan_language_packages` | `true` (CVEs) | `COLLECTOR_SCAN_LANGUAGE_PACKAGES` |
| `scan_secrets` | `false` | `COLLECTOR_SCAN_SECRETS` |
| `scan_ai_workloads` | `false` | `COLLECTOR_SCAN_AI_WORKLOADS` |
| `scan_data_volumes` | `true` | `COLLECTOR_SCAN_DATA_VOLUMES` |
| `scan_kubernetes_volumes` | `false` | `COLLECTOR_SCAN_KUBERNETES_VOLUMES` |

`scan_data_volumes` scans each VM's attached data disks as well as its boot disk. Before leaving it on:

- Each data disk keeps one more scanner snapshot, the next scan's differential base. Like the boot disk's, it is a restorable copy of the disk, readable by anyone with snapshot access in the project. Turning the input off keeps each disk's last snapshot until the disk is deleted; [Uninstalling](#uninstalling) has the command that deletes the scanner's snapshots.
- A VM with large data disks takes longer to scan.
- A data disk's packages are reported at the paths where the VM's `/etc/fstab` mounts it. A disk that `/etc/fstab` doesn't mount is still scanned for containers, but its packages are not counted as the VM's.
- It is a scanner setting, not a permission: the role can read every disk either way.
- Re-applying a deployment from an older release turns it on, since it defaults to `true`. Set it to `false` first if you don't want that.
- On Kubernetes nodes, GKE's included, it skips the disks Kubernetes created for persistent volume claims, recognised by the description Kubernetes writes on them: a pod's volume follows the pod, so it isn't the node's. `scan_kubernetes_volumes = "true"` scans them too, with their findings on each node a disk is attached to. Stream's console doesn't set that input, so re-applying from the console turns it back off. Skipping needs scanner v0.5.43 or later; older images always scan them, and a disk one scanned keeps that last snapshot until the disk is deleted.

A suffixed instance never scans disks, so both are always off there.

### Workload scanning

Besides VM disks, the scanner scans the images of the project's serverless workloads and GKE pods. Each kind has its own toggle, and its permissions are granted only while it is on.

| input | default | scans | permissions it adds |
|---|---|---|---|
| `scan_cloud_run` | `true` | Cloud Run services, including Cloud Run functions and gen2 Cloud Functions: the image of every revision serving traffic | `run.locations.list`, `run.services.list`, `run.revisions.get`, `artifactregistry.repositories.downloadArtifacts` |
| `scan_cloud_run_jobs` | `true` | Cloud Run jobs | `run.locations.list`, `run.jobs.list`, `artifactregistry.repositories.downloadArtifacts` |
| `scan_cloud_functions` | `true` | gen1 Cloud Functions, from their deployed source | `cloudfunctions.functions.list`, `cloudfunctions.functions.sourceCodeGet` |
| `scan_gke_images` | `true` | the images of the project's GKE pods, jobs and cron jobs, from the Stream inventory (needs the Stream Kubernetes agent on the cluster); covers pods no disk scan reaches, such as GKE Autopilot's | `artifactregistry.repositories.downloadArtifacts` |
| `scan_workload_only` | `false` | only the kinds above, no VM disks; needs at least one of them on | none |

They reach the scanner as `COLLECTOR_WORKLOAD_KINDS` (`none` when every kind is off) and `COLLECTOR_WORKLOAD_ONLY`. An image in another project's Artifact Registry also needs `roles/artifactregistry.reader` for the scanner's service account in that project.

What the workload permissions reach, so you can decide which kinds to leave on:

- They are all read-only and all within the basic Viewer role. `cloudfunctions.functions.sourceCodeGet` reads every function's deployed source, and listing services, jobs and functions returns their specs, plain environment variables included. The scanner uses only names, images and source, and uploads only package inventories.
- `artifactregistry.repositories.downloadArtifacts` is granted on the project, so it covers every repository and format in it, remote repositories included. IAM can't narrow it by format.
- Images still in legacy Container Registry storage, never migrated to Artifact Registry, also need `storage.objects.get` on `artifacts.<project>.appspot.com`. Without it those images fail to pull, and the rest of the scan continues.
- The workload scan runs as one Batch job in `region`, pulling images and source from every region of the project into that one.
- Re-applying a deployment from an older release turns the kinds on, since they default to `true`; `scan_gke_images` was added in v2.19.0. Set them to `false` first if you don't want that access. If you turned off `scan_cloud_run` and `scan_cloud_run_jobs` to withhold registry access, also set `scan_gke_images` to `false`: on its own it grants `artifactregistry.repositories.downloadArtifacts` again.
- `scan_gke_images` asks Stream, not GCP, for the images, at most 2,000 per run, the most-run first. The images are whatever the clusters' pod specs name. Docker Hub images are pulled through `mirror.gcr.io`, falling back to Docker Hub, whose anonymous pull limit applies to the NAT's IP; images from other registries outside Google are pulled anonymously, so private ones fail, and the rest of the scan continues. It needs scanner v0.5.38 or later; older images skip it with a warning, so with `scan_workload_only` and no other kind on, every run's workload scan fails.
- `scan_workload_only` skips the disk scan but keeps its permissions for now, since the snapshot sweep still runs in that mode.
- The kinds need a scanner image with GCP workload scanning, newer than v0.5.21. Older images ignore them, and with `scan_workload_only` an older image scans nothing.

### Projects that restrict resource locations

Under a `constraints/gcp.resourceLocations` org policy, the policy must allow `region`, where Stream's console also creates the Infra Manager deployment, and the region of every VM the scanner scans. Check it with `gcloud org-policies describe constraints/gcp.resourceLocations --project=<PROJECT_ID> --effective`.

- **Secrets:** both are created with one replica in `region`, and stay there if `region` later changes. A deployment created on an older release keeps its secrets' automatic replication, in `global`. Replication can't change in place, so the module leaves it rather than replacing the secrets, and a location policy doesn't apply to resources that already exist.
- **Snapshots:** scanner images v0.5.31 and later store each disk's snapshot in that disk's region. Older images leave the location to the project's snapshot settings, by default the nearest multi-region (`us` for `us-central1`), so a policy without it fails every disk scan while the apply succeeds.

### Scanning other projects (hub)

A scanner can also scan other projects of the organization, the ones chosen in Stream, which makes its project the organization's hub. Its snapshots and scan disks stay in the hub, and nothing is created in the projects it scans. Beyond this module, a hub needs:

- **Access to those projects:** one organization custom role, `streamsecVolumeScannerTarget`, granted to the scanner's service account on the organization, on folders, or on projects. Stream's console renders a gcloud command that creates and grants it; [`modules/volume-scanner-hub-access`](../volume-scanner-hub-access) does the same with your own Terraform, and lists the rights either needs.
- **Worker regions:** `worker_regions` must cover the regions of the VMs in every project it scans. The apply command Stream's console renders for a hub lists them.
- **Customer-managed keys:** to scan a disk encrypted with one, the hub's Compute Engine service agent needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key.

Before scanning a project, the scanner reads it through Resource Manager, which checks its access and gives the project number. A project it can't read is reported as *No access* in Stream and skipped; the others are scanned. Resource Manager counts the call against the scanner's own project, so the module enables that API in it.

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
- **Delete outside the daily scan, and after the first scan,** which starts at install or at an update to v2.21.0. GCP doesn't delete the scanner's subnet while scan workers still run on it.
- **From your own root,** bump `version` past v2.15.0 and apply before `terraform destroy`.
- **A hub's** binding to the other projects is not part of its deployment, and deleting the deployment deletes the scanner service account it names. The binding then grants nothing, and shows as `deleted:serviceAccount:…`. Where you applied [`modules/volume-scanner-hub-access`](../volume-scanner-hub-access), remove the hub from `hub_project_ids`, even if it is the last one, and apply: until you do, that stack's applies fail on the missing account. If you used the console's command, remove the binding with gcloud. A redeployed hub has a new service account, so grant it again. Every hub of the organization shares the role, so delete it only when no hub uses it.
- **A change that replaces the job,** such as a new `region`, fails the same way on those deployments. Re-apply from a newer release with no other change first.

Then delete the scanner's snapshots. It keeps one per scanned disk as the next scan's base, and Terraform doesn't track them. gcloud lists them and asks before deleting. Skip this when removing only a suffixed instance: it makes none, so these belong to the other instance.

```bash
gcloud compute snapshots delete --project=<PROJECT_ID> \
  $(gcloud compute snapshots list --project=<PROJECT_ID> --filter="labels.purpose=cloud-volume-scanner" --format="value(name)")
```
