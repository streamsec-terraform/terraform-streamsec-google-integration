## Stream Security GKE logs collection (GCP)

This Terraform module deploys a GCP pipeline that exports **GKE audit/activity logs** (via an **organization-level Logging sink**) to a GCS bucket, then triggers a Cloud Function to forward/ingest them into **Stream Security**.

### What this module creates

- **Required APIs** enabled in the target project (Logging, Storage, Cloud Functions, Secret Manager, IAM, Pub/Sub, Cloud Build, Monitoring)
- **GCS logs bucket** (destination of the org sink)
  - **Note**: the final bucket name is `${bucket_name}-<random_suffix>` to ensure global uniqueness
  - 30-day retention policy (unlocked)
- **Organization-level Logging sink** with `include_children = true`
  - Filter targets `resource.type="k8s_cluster"` and excludes common “system” noise
- **IAM bindings** so the sink can write into the logs bucket
- **Secret Manager secret + version** holding your Stream Security collection token
- **Artifact bucket** in your project plus a copy of the public StreamSec function zip into it
- **Cloud Function (Gen1)** triggered by `google.storage.object.finalize` events on the logs bucket
- **Function service account** + IAM to read the Secret Manager secret

### Prerequisites

- **Terraform**: `>= 1.5.0`
- **Google credentials** available to Terraform (Application Default Credentials recommended)
  - Examples:
    - `gcloud auth application-default login`
    - or set `GOOGLE_APPLICATION_CREDENTIALS` to a service account key JSON (CI)
- **gsutil installed** on the machine running Terraform
  - This module uses a `local-exec` provisioner to run `gsutil cp ...` to copy the public artifact zip into your project’s artifact bucket.
- **Permissions**
  - You must be able to create an **organization logging sink** (org-level permissions).
  - You must be able to create/manage resources in the **target project** (enable services, buckets, secrets, IAM, Cloud Functions).
  - Simplest: run with an identity that is **Project Owner** on `project_id` and has an org role that allows **Logging sink configuration** (for example, Logging Admin / Logs Configuration Writer at the org level).

### Configuration

1) Copy the example tfvars.

```bash
cp terraform.tfvars.example terraform.tfvars
```

2) Edit `terraform.tfvars` and set the required values.

- **`project_id`**: Project where the bucket/secret/function will live
- **`org_id`**: Numeric GCP organization ID (sink is created at org scope)
- (optional) **`region`**: Cloud Function region (default: `us-central1`)
- (optional) **`bucket_name`**: Bucket name where GKE logs will be stored
- (optional) **`bucket_location`**: Bucket location (default: `US`)
- (optional) **`api_url`**: Your custom Stream Security base URL
- (optional) **`secret_name`**: Secret name (default: `streamsec-gke-logs-token`)
- **`streamsec_token`**: Stream Security collection token (sensitive)

### Security note about the token

Even though `streamsec_token` is marked `sensitive`, Terraform will still store it in **Terraform state** (and it will also be written to Secret Manager as a secret version). Protect your state accordingly (secure backend, encryption, least-privilege access).

If you want to avoid committing secrets, do **not** put `streamsec_token` in `terraform.tfvars`. Instead set it via an environment variable:

```bash
export TF_VAR_streamsec_token="YOUR_STREAMSEC_TOKEN"
```

### Deploy

From this directory:

```bash
terraform init
terraform plan
terraform apply
```

### Verify

- **Org sink exists**: In Cloud Console → Logging → Log Router → Sinks (Organization)
- **Logs bucket**: Storage bucket exists in `project_id` and has new objects written by the sink
- **Cloud Function**: Deployed in `region`, triggered by GCS finalize events on the logs bucket
- **Secret Manager**: Secret `${secret_name}` exists and has a version

Terraform outputs you can use:

- `logs_bucket`: the final bucket name created (includes the random suffix)
- `function_name`: deployed Cloud Function name
- `secret_resource_path`: secret version reference used by the function
- `org_sink_writer_identity`: sink service account used for bucket writes

### Cleanup

```bash
terraform destroy
```

**Note**: The logs bucket is created with a **30-day retention policy** and `force_destroy = false`. If log objects exist in the bucket, `terraform destroy` may fail. You may need to:

- Remove/shorten the retention policy (and wait for it to take effect), and/or
- Delete objects in the bucket (if permitted by retention), then re-run `terraform destroy`

### Troubleshooting

- **`gsutil: command not found`**
  - Install the Google Cloud SDK (or run from Cloud Shell), and ensure `gsutil` is on `PATH`.
- **Org sink creation fails**
  - Confirm you’re using credentials with org-level permissions to create Logging sinks.
- **No objects arrive in the bucket**
  - Confirm the sink filter matches your environment and that `include_children = true` is appropriate for your org structure.
  - Check that the sink writer identity has `roles/storage.objectCreator` on the logs bucket.
- **`terraform destroy` fails deleting the logs bucket**
  - The bucket may not be empty, or object retention may be preventing deletions. See the note in [Cleanup](#cleanup).
