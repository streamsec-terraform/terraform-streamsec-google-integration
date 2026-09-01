## Stream Security agentless volume scanner (GCP)

Agentless vulnerability scanning of Compute Engine disks. The scanner runs
**inside your project**, snapshots disks, extracts SBOMs and ships them to
Stream Security for CVE matching. No agent is installed on any instance, and
Stream is granted no inbound credentials — every callback is outbound, and
authenticated by tokens minted for this deployment.

### What this module creates

- **Required APIs** enabled in the target project (Compute, Batch, Cloud Run, Cloud Scheduler, Secret Manager)
- **Service account** shared by the orchestrator and its workers
- **Least-privilege custom role** — discover VMs, snapshot/attach disks, run Batch workers; no data-plane read beyond the disks it scans
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
