# Stream Security file collector for Cloud Storage (GCP)

Sends every file written to a Cloud Storage bucket to a Stream Security collection
endpoint. It is the GCP counterpart of the AWS `s3-file-collector` stack and the Azure
file collector. Its first use is the audit log GitHub Enterprise streams into a bucket
(`api_url_suffix = "github-audit"`).

Each new object (`google.cloud.storage.object.v1.finalized`) is read whole and posted
as `{"data": "<base64 of the object>"}` to
`<stream_api_url>/api/v1/collection/<api_url_suffix>`, with the collection token in the
`X-Lightlytics-Token` header.

- Only gzip objects are sent. GitHub writes its audit log as gzipped NDJSON, and
  `/collection/github-audit` unpacks a payload only when it is gzip; anything else is
  read as a single webhook event. Other objects, such as a stream check file, are skipped.
- The stored bytes are read (`raw_download`), so an object written with
  `Content-Encoding: gzip` is not decompressed on the way.
- A delivery that fails with a 5xx, 408 or 429, or cannot reach Stream Security, is
  retried by Eventarc for up to 24 hours. Any other 4xx (a revoked token, a payload too
  large) is logged and not retried.

## Resources

- Required Google APIs
- A collector service account: it runs the function, reads the bucket
  (`roles/storage.objectViewer` on the bucket), receives the events
  (`roles/eventarc.eventReceiver`) and is the only identity allowed to invoke the function
- A build service account, so builds do not depend on a default service account
- `roles/pubsub.publisher` for the project's Cloud Storage service agent, which publishes
  the bucket's events. Every Cloud Storage trigger in the project shares this grant, so
  destroying the deployment that holds it takes it from all of them. With more than one
  collector, or other Cloud Storage triggers in the project, set
  `grant_storage_agent_publisher = false` and grant it once outside any deployment. The
  Infrastructure Manager path does this: the console's setup step grants it.
- Secret Manager secret for the collection token
- Python 3.12 Gen2 Cloud Function (`collect`) with an Eventarc trigger on the bucket,
  in the bucket's location
- Source archive bucket; the archive is named by its content, so a new release of the
  code redeploys the function
- With `deployment_service_account_email`, a custom role that lets that account set the
  IAM policies of the bucket, the build repository, the Cloud Run service and the secret

The bucket must be in `project_id`: Eventarc delivers Cloud Storage events only to
triggers in the bucket's project. The module reads the bucket while planning, so a bucket
in another project stops the plan before anything changes.
Resource names carry the endpoint and a hash of the endpoint and bucket, so one project
can run a collector per bucket.

## Ways to deploy

- **Infrastructure Manager**, from the Stream Security console: it renders a
  `gcloud infra-manager deployments apply` command for
  `infrastructure-manager/gcs-file-collector`, pinned to a release.
- **gcloud only**: [`scripts/deploy-gcs-file-collector.sh`](../../scripts/README.md#deploy-gcs-file-collectorsh)
  deploys the same function code with the same resource names, without Terraform.
- **Terraform**: use the module directly.

```hcl
module "github_audit_logs" {
  source = "github.com/streamsec-terraform/terraform-streamsec-google-integration//modules/gcs-file-collector?ref=<release>"

  project_id              = "acme-logs"
  bucket_name             = "acme-github-audit"
  api_url_suffix          = "github-audit"
  stream_api_url          = "https://acme.streamsec.io"
  stream_collection_token = var.github_collection_token
}
```

## Checking it

Each file sent logs `Sent gs://<bucket>/<object>`:

```sh
gcloud functions logs read <function_name> --project <project_id> --region <region> --limit 10
```

On a first deploy, deliveries in the first minutes can fail with 403 while the new
service account's permissions propagate. Eventarc retries them.

In projects created before April 8, 2021, the Pub/Sub service agent also needs
`roles/iam.serviceAccountTokenCreator` for Eventarc to deliver; see the Eventarc
documentation.

## Tests

```sh
terraform test                                  # in this directory, mocked providers
python -m pytest tests                          # the function; needs function_source/requirements.txt and pytest
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | Project to deploy into; it must hold `bucket_name` | |
| `bucket_name` | Bucket the files are written to, without `gs://` | |
| `api_url_suffix` | Collection endpoint, e.g. `github-audit` | |
| `stream_api_url` | The URL you open Stream Security at | |
| `stream_collection_token` | Collection token of the integration (sensitive) | |
| `region` | Region of the function and its build resources | `us-central1` |
| `function_timeout_seconds` | Timeout of one file's delivery | `120` |
| `max_instance_count` | Function instances delivering at once | `10` |
| `manage_apis` | Enable the APIs the collector needs | `true` |
| `grant_storage_agent_publisher` | Grant the Cloud Storage service agent `roles/pubsub.publisher`; see above | `true` |
| `deployment_service_account_email` | Account Terraform runs as when it lacks resource-level setIamPolicy (the Infrastructure Manager runner) | `""` |
| `labels` | Labels added to the resources | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `function_name` | Name of the collector function |
| `function_state` | `ACTIVE` once deployed |
| `trigger` | Eventarc trigger delivering the bucket's new files |
| `service_account_email` | Identity the function reads and receives events as |
| `deployer_role` | Custom role granted to `deployment_service_account_email`, or null |
| `collection_url` | Stream Security endpoint the files are sent to |
