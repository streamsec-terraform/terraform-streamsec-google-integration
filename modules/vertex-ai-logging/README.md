# Vertex AI Logging Module

Terraform module that deploys a log collection pipeline for GCP Vertex AI request-response logs.
A Cloud Function polls BigQuery on a schedule, converts rows to GCP audit log format,
and forwards them to the Stream Security platform.

## Architecture

```
Vertex AI Endpoint (request-response logging enabled)
        │
        ▼
BigQuery (streamsec_vertex_ai_logs.request_response_logging*)
        │  polled every 5 min
        ▼
Cloud Scheduler ──► Cloud Function (2nd Gen)
                          │
                          ▼
               Stream Security API
        (/api/v1/collection/gcp-audit-log)
```

## Prerequisites

- A **configured `restapi` provider** passed in by the caller, when `enable_request_response_logging` is `true` (see [How Logging Is Enabled](#how-logging-is-enabled)). No Python, and nothing needs to be installed on the machine running Terraform.
- **Stream Security API token already stored in Secret Manager** in the same project. This module *reads* the token — it does **not** create the secret. It derives the secret's full version path from the shared `secret_name` / `regional_secret` inputs (the same ones the `real-time-events` module uses to create it), so set them to match. Global and regional secrets are both supported. `use_secret_manager` must be `true`.
- Required GCP APIs are enabled automatically by the module (toggle with `manage_apis`)
- Only the Google provider is required (ADC). This module does **not** use the `streamsec` provider — the collection URL is supplied directly via `api_url`, so it can be applied standalone without Stream Security API credentials.

## Collection URL

The function posts to `<api_url>/api/v1/collection/gcp-audit-log`.

- `api_url` is **required** and must be the full URL including scheme, e.g. `https://app.streamsec.io`
  (or a non-prod host such as `https://tenant1.staging.streamsec.io`).
- Resource names are prefixed with `name_prefix` (default `streamsec`): `streamsec-vertex-ai-collector`,
  `streamsec-vertex-ai-poll`, etc. The BigQuery dataset uses the same prefix with underscores
  (`streamsec_<bigquery_dataset>`, e.g. `streamsec_vertex_ai_logs`), since dataset IDs disallow hyphens.
- The module deploys **one pipeline per project**. To run more than one in a single project, give each
  a distinct `name_prefix`.

## Usage

```hcl
module "vertex_ai_logging" {
  source = "./modules/vertex-ai-logging"

  project_id = "my-gcp-project"
  region     = "us-central1"

  # REQUIRED. Full Stream Security collection URL (scheme included).
  api_url = "https://app.streamsec.io" # e.g. https://tenant1.staging.streamsec.io for non-prod

  # Shared token secret (created by real-time-events). Match its inputs so the derived
  # secret version path resolves to the same secret. The module reads, never creates, it.
  use_secret_manager = true
  secret_name        = "stream-security-collection-token"
  regional_secret    = true # match real-time-events (true = regional, false = global)
  # secret_version_name = "projects/<p>/.../versions/latest" # optional explicit override

  # Set to false if the dataset already exists. The effective dataset id is prefixed:
  # <name_prefix>_<bigquery_dataset> (e.g. streamsec_vertex_ai_logs).
  create_bigquery_dataset     = true
  bigquery_dataset            = "vertex_ai_logs"
  bigquery_table              = "request_response_logging"
  bigquery_location           = "US"
  bigquery_log_retention_days = 30

  schedule_cron = "*/5 * * * *"
  batch_size    = 20

  # Publisher model logging (enabled by default)
  enable_request_response_logging = true
  vertex_ai_models                = ["gemini-2.5-flash", "gemini-2.5-pro"]
  logging_sampling_rate           = 1.0
}
```

### Multiple pipelines in one project

The module deploys a single pipeline per project. To run more than one in the same project,
give each a distinct `name_prefix` (which prefixes every resource name and the dataset) and
set `manage_apis = false` on all but the first so they don't redundantly own the shared
`google_project_service` resources.

```bash
# pipeline "app"
terraform apply -var="project_id=my-gcp-project" -var="api_url=https://app.streamsec.io" \
  -var="secret_name=streamsec-vtx-token-app"

# a second pipeline in the same project
terraform apply -var="project_id=my-gcp-project" -var="api_url=https://demo.streamsec.io" \
  -var="name_prefix=streamsec-demo" -var="secret_name=streamsec-vtx-token-demo" \
  -var="manage_apis=false"
```

## How Logging Is Enabled

Logging is configured per publisher model by one `restapi_object.publisher_model_logging` resource
per entry in `vertex_ai_models`.

**Why not a native resource?** The Google provider's `predict_request_response_logging_config`
block exists only on `google_vertex_ai_endpoint`, which covers self-deployed endpoints. Serverless
publisher models (`gemini-*`) have no Endpoint resource — they are configured through aiplatform's
`:setPublisherModelConfig` REST method. A native resource is requested upstream in
[hashicorp/terraform-provider-google#24092](https://github.com/hashicorp/terraform-provider-google/issues/24092)
but is not yet implemented, so the module drives that method through the `restapi` provider.

Because create, update and destroy are all `POST`s to the same method, the resource sets
`update_method`/`destroy_method` to `POST` explicitly. `destroy_data` sends `enabled: false`, so
`terraform destroy` turns logging **off** rather than leaving it pointed at a deleted dataset.
Every write carries `updateMask: "loggingConfig"` so it does not clobber sibling settings on the
model (`claudeFeatureConfig`, `inferenceEventLoggingConfig`, `dataSharingEnabledProvider`).

### Supplying the provider

This module declares `restapi` but does **not** configure it: a module containing a provider block
cannot be used with `count`, `for_each` or `depends_on`, and the root module wires this one with
both. Configure it in your root and it is inherited automatically:

```hcl
data "google_client_config" "default" {}

provider "restapi" {
  # Regional host — must match the module's `region`.
  uri = "https://us-central1-aiplatform.googleapis.com"

  headers = {
    Authorization  = "Bearer ${data.google_client_config.default.access_token}"
    "Content-Type" = "application/json"
  }

  # :setPublisherModelConfig returns a long-running Operation, not the object.
  write_returns_object  = false
  create_returns_object = false
}
```

The token is short-lived (~1h) and read at plan time; a plan left sitting for hours before apply
can fail with `401`, in which case re-run the plan.

Set `enable_request_response_logging = false` to skip all of this — no `restapi_object` resources
are created and the provider does not need to be configured at all.

> **Note:** this config is singular per model + location for the entire project. Enabling it here
> overwrites the BigQuery destination any other deployment set on the same model in the same
> region.

**Known limitation:** `fetchPublisherModelConfig` returns a bare `PublisherModelConfig` while the
write body wraps it in `publisherModelConfig` plus `updateMask`, so the two shapes can never
compare equal. The resource therefore sets `ignore_all_server_changes = true`: changes you make to
the Terraform config are applied normally, but drift introduced **outside** Terraform (e.g. someone
disabling logging in the console) is not detected. Re-apply to reassert the intended config.

## Permissions granted

Data access is scoped to the logging dataset, not the project — the collector forwards what it
reads to an external endpoint, so a project-wide `bigquery.dataViewer` would put every unrelated
dataset in the blast radius of a compromise.

| Identity | Role | Scope |
|---|---|---|
| Collector SA | `bigquery.dataViewer` (or dataset `READER`) | the logging dataset only |
| Collector SA | `roles/bigquery.jobUser` | project — no dataset-scoped equivalent exists, and it grants no data access on its own |
| Collector SA | `roles/secretmanager.secretAccessor` | the one token secret (toggle with `manage_secret_iam`) |
| Collector SA | `roles/storage.objectAdmin` | the watermark bucket only |
| Vertex AI service agent | `bigquery.dataEditor` (or dataset `WRITER`) | the logging dataset only |

When `create_bigquery_dataset = true` the two dataset roles come from the dataset's own `access`
blocks; when it's `false` they come from `google_bigquery_dataset_iam_member` resources instead.
The two mechanisms are mutually exclusive on a single dataset, which is why they're `count`-gated.

### If the apply fails with `bigquery.datasets.update denied`

In BigQuery a dataset's ACL **is** part of the dataset resource, so *any* dataset-scoped grant —
`access` block or `google_bigquery_dataset_iam_member` alike — is a `datasets.update` call. A
deployer holding only `bigquery.datasets.create` (e.g. project-level `roles/bigquery.dataEditor`)
can create the dataset but cannot later modify its access list, and the apply fails with:

```
Error 403: Access Denied: Dataset <project>:<dataset>: Permission bigquery.datasets.update denied
```

Two ways out:

1. **Preferred** — grant the deployer `roles/bigquery.dataOwner` on the logging dataset, then keep
   `bigquery_grant_scope = "dataset"`.
2. **Fallback** — set `bigquery_grant_scope = "project"`. Both roles are granted as project-level
   bindings instead, which needs only project `setIamPolicy`. Broader: the collector can read every
   dataset in the project and the service agent can modify every dataset, and because the bindings
   are additive, `terraform destroy` revokes them for anything else relying on the same grant.

`bigquery_grant_scope = "none"` skips both, for IAM managed entirely out-of-band. `bigquery.jobUser`
is granted at project level in all three cases — it has no dataset-scoped equivalent.

## Delivery semantics

At-least-once. Each poll reads rows `WHERE logging_time > watermark ORDER BY logging_time ASC`,
and the watermark advances only across the unbroken **leading run** of rows that were actually
delivered. A failure partway through a batch leaves the watermark at the last confirmed row, so
the remainder is re-queried on the next poll — duplicates are possible, dropped rows are not.
Deduplicate downstream on `request_id`. A poll that delivers nothing while rows exist returns
`500` so Cloud Scheduler retries and the failure is visible.

**Known gap ([#43](https://github.com/streamsec-terraform/terraform-streamsec-google-integration/issues/43)):**
the cursor is event-time only. `logging_time` is when the request was served; the row becomes
visible in BigQuery later. Because the watermark advances to the newest row a poll saw,
fast-arriving rows drag it past slow-arriving neighbours, and any row lagging more than about a
poll interval behind its peers is dropped. (The same cursor also skips the remainder of a group
of rows sharing one `logging_time` if the 10,000-row limit splits it, though that needs ~10k
requests in a single microsecond and is effectively unreachable.)

Each poll logs `vertex_ingestion_lag_seconds` as structured JSON — `min`/`p50`/`p95`/`max` age of
the rows it made visible — so the window for the fix can be sized from observed data. The `min`
approximates current ingestion lag; the spread across polls is what determines exposure:

```bash
gcloud logging read \
  'resource.type=cloud_run_revision AND jsonPayload.metric="vertex_ingestion_lag_seconds"' \
  --project=my-gcp-project --limit=50 --format='value(jsonPayload)'
```

## Testing

### 1. Send a Test Prompt

Send a prompt to generate a log entry in BigQuery.

**Python SDK:**

```python
import vertexai
from vertexai.preview.generative_models import GenerativeModel

vertexai.init(project="my-gcp-project", location="us-central1")

model = GenerativeModel("gemini-2.5-flash")
response = model.generate_content("What is 2+2? Reply in one word.")
print(f"Response: {response.text}")
```

**REST API (from a GCE instance or Cloud Shell):**

```bash
TOKEN=$(gcloud auth print-access-token)

curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/my-gcp-project/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent" \
  -d '{
    "contents": [{
      "role": "user",
      "parts": [{"text": "Say hello in exactly 5 words"}]
    }]
  }'
```

### 2. Verify Logs Appear in BigQuery

Logs typically appear 2–3 minutes after the prompt is sent.

```bash
bq query --project_id=my-gcp-project --use_legacy_sql=false --format=pretty \
  'SELECT logging_time, model, api_method
   FROM `my-gcp-project.streamsec_vertex_ai_logs.request_response_logging*`
   ORDER BY logging_time DESC
   LIMIT 5'
```

### 3. Trigger the Cloud Function Manually

After verifying logs exist in BigQuery, trigger the collector function to confirm
end-to-end delivery to Stream Security.

```bash
FUNCTION_URL=$(terraform output -raw function_url)

curl -s -X POST "$FUNCTION_URL" \
  -H "Authorization: bearer $(gcloud auth print-identity-token)" \
  -H "Content-Type: application/json" \
  -d '{}'
```

### 4. Verify Cloud Scheduler Runs

Check that the scheduled trigger is firing correctly. Resource names are prefixed with
`name_prefix` (e.g. `streamsec-vertex-ai-poll`), so prefer the module outputs:

```bash
gcloud scheduler jobs describe "$(terraform output -raw scheduler_job_name)" \
  --project=my-gcp-project \
  --location=us-central1

# Check recent execution logs
gcloud functions logs read "$(terraform output -raw function_name)" \
  --project=my-gcp-project \
  --region=us-central1 \
  --limit=20
```

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `project_id` | GCP project ID | `string` | — |
| `region` | GCP region | `string` | `us-central1` |
| `api_url` | **Required.** Full Stream Security collection URL, `https://` only (`http://localhost` allowed for dev), e.g. `https://app.streamsec.io` | `string` | — |
| `manage_apis` | Whether this deployment enables the required project APIs (false when already owned elsewhere in the project) | `bool` | `true` |
| `use_secret_manager` | Token is stored in Secret Manager (must be `true`) | `bool` | `true` |
| `secret_name` | Secret ID of the shared API-token secret (match `real-time-events`) | `string` | `stream-security-collection-token` |
| `secret_project` | Project owning the shared secret, when it isn't `project_id` (needed when `real-time-events` created it in `project_for_resources` only) | `string` | `""` |
| `regional_secret` | Whether the shared secret is regional (`true`) or global (`false`); match `real-time-events` | `bool` | `true` |
| `secret_version_name` | Optional explicit full secret VERSION resource name; overrides the derived path | `string` | `""` |
| `bigquery_grant_scope` | Where BigQuery access is granted: `dataset` (least privilege, needs `bigquery.datasets.update`), `project` (fallback), or `none` | `string` | `dataset` |
| `create_bigquery_dataset` | Create the BigQuery dataset | `bool` | `true` |
| `bigquery_dataset` | BigQuery dataset ID base; effective dataset is `<name_prefix>_<bigquery_dataset>` | `string` | `vertex_ai_logs` |
| `bigquery_table` | BigQuery table the publisher model logs to (no trailing underscore) | `string` | `request_response_logging` |
| `bigquery_location` | BigQuery dataset location | `string` | `US` |
| `bigquery_log_retention_days` | Log retention in days | `number` | `30` |
| `schedule_cron` | Cloud Scheduler cron expression | `string` | `*/5 * * * *` |
| `function_memory_mb` | Cloud Function memory (MB) | `number` | `512` |
| `function_timeout_seconds` | Cloud Function timeout | `number` | `300` |
| `batch_size` | Concurrent HTTP requests to Stream Security (positive integer) | `number` | `20` |
| `name_prefix` | Resource name prefix | `string` | `streamsec` |
| `enable_request_response_logging` | Manage publisher-model logging via `restapi_object` (requires a configured `restapi` provider) | `bool` | `true` |
| `vertex_ai_models` | Publisher model names to enable logging on (one logging config per model, shared dataset) | `list(string)` | `["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"]` |
| `logging_sampling_rate` | Fraction of requests to log (0.0–1.0) | `number` | `1.0` |
| `labels` | Labels applied to all resources | `map(string)` | `managed-by=terraform, component=streamsec-vertex-ai-collection` |

## Outputs

| Name | Description |
|------|-------------|
| `collection_url` | Collection base URL the function posts to (`api_url`) |
| `function_name` | Deployed Cloud Function name |
| `function_url` | Cloud Function URL (for manual trigger) |
| `service_account_email` | Service account used by the function |
| `scheduler_job_name` | Cloud Scheduler job name |
| `watermark_bucket` | GCS bucket for watermark state |
| `bigquery_dataset_id` | Effective (prefixed) BigQuery dataset ID, `<name_prefix>_<bigquery_dataset>` |
| `bigquery_table_prefix` | BigQuery table prefix |
