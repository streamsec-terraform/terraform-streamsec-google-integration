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

- Python 3 with the `google-cloud-aiplatform` SDK installed (used by `local-exec` to enable logging on each publisher model)
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

The module uses one `null_resource` per model in `vertex_ai_models` with `local-exec` to run a
Python script that calls the Vertex AI SDK's `set_request_response_logging_config()`. This runs
automatically during `terraform apply` and re-runs for a model when its name, the sampling rate,
or the dataset changes.

The machine running Terraform must have:
- Python 3 with `google-cloud-aiplatform` installed (`pip install google-cloud-aiplatform`)
- GCP credentials with permissions to configure Vertex AI endpoints

Set `enable_request_response_logging = false` to skip this step (e.g., if logging is
already configured manually or managed elsewhere).

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
| `api_url` | **Required.** Full Stream Security collection URL (scheme included), e.g. `https://app.streamsec.io` | `string` | — |
| `manage_apis` | Whether this deployment enables the required project APIs (false when already owned elsewhere in the project) | `bool` | `true` |
| `use_secret_manager` | Token is stored in Secret Manager (must be `true`) | `bool` | `true` |
| `secret_name` | Secret ID of the shared API-token secret (match `real-time-events`) | `string` | `stream-security-collection-token` |
| `regional_secret` | Whether the shared secret is regional (`true`) or global (`false`); match `real-time-events` | `bool` | `true` |
| `secret_version_name` | Optional explicit full secret VERSION resource name; overrides the derived path | `string` | `""` |
| `create_bigquery_dataset` | Create the BigQuery dataset | `bool` | `true` |
| `bigquery_dataset` | BigQuery dataset ID base; effective dataset is `<name_prefix>_<bigquery_dataset>` | `string` | `vertex_ai_logs` |
| `bigquery_table` | BigQuery table the publisher model logs to (no trailing underscore) | `string` | `request_response_logging` |
| `bigquery_location` | BigQuery dataset location | `string` | `US` |
| `bigquery_log_retention_days` | Log retention in days | `number` | `30` |
| `schedule_cron` | Cloud Scheduler cron expression | `string` | `*/5 * * * *` |
| `function_memory_mb` | Cloud Function memory (MB) | `number` | `512` |
| `function_timeout_seconds` | Cloud Function timeout | `number` | `300` |
| `batch_size` | Concurrent HTTP requests to Stream Security | `number` | `20` |
| `name_prefix` | Resource name prefix | `string` | `streamsec` |
| `enable_request_response_logging` | Enable logging on publisher model via local-exec | `bool` | `true` |
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
