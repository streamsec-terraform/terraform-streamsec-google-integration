# Vertex AI Logging Module

Terraform module that deploys a log collection pipeline for GCP Vertex AI request-response logs.
A Cloud Function polls BigQuery on a schedule, converts rows to GCP audit log format,
and forwards them to the Stream Security platform.

## Architecture

```
Vertex AI Endpoint (request-response logging enabled)
        │
        ▼
BigQuery (vertex_ai_logs.predictions_*)
        │  polled every 5 min
        ▼
Cloud Scheduler ──► Cloud Function (2nd Gen)
                          │
                          ▼
               Stream Security API
        (/api/v1/collection/gcp-audit-log)
```

## Prerequisites

- Python 3 with the `google-cloud-aiplatform` SDK installed (used by `local-exec` to enable logging on the publisher model)
- **Stream Security API token already stored in Secret Manager** in the same project. This module *reads* the token — it does **not** create the secret. It derives the secret's full version path from the shared `secret_name` / `regional_secret` inputs (the same ones the `real-time-events` module uses to create it), so set them to match. Global and regional secrets are both supported. `use_secret_manager` must be `true`.
- Required GCP APIs are enabled automatically by the module (toggle with `manage_apis`)
- Only the Google provider is required (ADC). This module does **not** use the `streamsec` provider — the collection URL is built from `env` + `streamsec_domain`, so it can be applied standalone without Stream Security API credentials.

## Collection URL & environments

The function posts to `https://<env>.<streamsec_domain>/api/v1/collection/gcp-audit-log`.

- `env` is **required** and also suffixes every resource name (`...-<env>`), so the module can be deployed **once per environment** against the same project without collisions.
- `streamsec_domain` (default `streamsec.io`) selects the target environment family:

  | `env` | `streamsec_domain` | Resulting URL |
  |-------|--------------------|---------------|
  | `app` | `streamsec.io` (default) | `https://app.streamsec.io` |
  | `tenant1` | `staging.streamsec.io` | `https://tenant1.staging.streamsec.io` |
  | `tenant1` | `dev.streamsec.io` | `https://tenant1.dev.streamsec.io` |

- Set `api_url` to override the full URL explicitly (bypasses `env` + `streamsec_domain`).

## Usage

```hcl
module "vertex_ai_logging" {
  source = "./modules/vertex-ai-logging"

  project_id = "my-gcp-project"
  region     = "us-central1"

  # REQUIRED: environment / subdomain prefix. Drives the URL and resource naming.
  env              = "app"
  streamsec_domain = "streamsec.io" # override for staging/dev, e.g. "staging.streamsec.io"

  # Shared token secret (created by real-time-events). Match its inputs so the derived
  # secret version path resolves to the same secret. The module reads, never creates, it.
  use_secret_manager = true
  secret_name        = "stream-security-collection-token"
  regional_secret    = true # match real-time-events (true = regional, false = global)
  # secret_version_name = "projects/<p>/.../versions/latest" # optional explicit override

  # Set to false if the dataset already exists
  create_bigquery_dataset     = true
  bigquery_dataset            = "vertex_ai_logs"
  bigquery_table              = "predictions_"
  bigquery_location           = "US"
  bigquery_log_retention_days = 30

  schedule_cron = "*/5 * * * *"
  batch_size    = 20

  # Publisher model logging (enabled by default)
  enable_request_response_logging = true
  vertex_ai_model                 = "gemini-2.5-flash"
  logging_sampling_rate           = 1.0
}
```

### Deploying multiple environments

Apply the module once per environment with isolated state (a Terraform workspace or a
separate state file per env). Each run targets a different env and gets its own
`...-<env>` service account, bucket, function, and scheduler.

```bash
# env "app" -> https://app.streamsec.io
terraform workspace new app
terraform apply -var="project_id=my-gcp-project" -var="env=app" \
  -var="secret_name=streamsec-vtx-token-app"

# env "demo" -> https://demo.streamsec.io (same project, no collisions)
terraform workspace new demo
terraform apply -var="project_id=my-gcp-project" -var="env=demo" \
  -var="secret_name=streamsec-vtx-token-demo" -var="manage_apis=false"
```

> When deploying additional environments into the **same** project, set `manage_apis = false`
> on all but the first so they don't redundantly own the shared `google_project_service` resources.

## How Logging Is Enabled

The module uses a `null_resource` with `local-exec` to run a Python script that calls
the Vertex AI SDK's `set_request_response_logging_config()`. This runs automatically
during `terraform apply` and re-runs when the model, sampling rate, or dataset changes.

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
   FROM `my-gcp-project.vertex_ai_logs.predictions_*`
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

Check that the scheduled trigger is firing correctly. Resource names are suffixed with
`env` (e.g. `streamsec-vertex-ai-poll-app`), so prefer the module outputs:

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
| `env` | **Required.** Environment / subdomain prefix; drives the URL and suffixes resource names | `string` | — |
| `streamsec_domain` | Base domain for the collection URL (`https://<env>.<streamsec_domain>`); set for staging/dev | `string` | `streamsec.io` |
| `api_url` | Optional explicit collection URL override (bypasses env + domain) | `string` | `""` |
| `manage_apis` | Whether this deployment enables the required project APIs (false for extra per-env deploys in the same project) | `bool` | `true` |
| `use_secret_manager` | Token is stored in Secret Manager (must be `true`) | `bool` | `true` |
| `secret_name` | Secret ID of the shared API-token secret (match `real-time-events`) | `string` | `stream-security-collection-token` |
| `regional_secret` | Whether the shared secret is regional (`true`) or global (`false`); match `real-time-events` | `bool` | `true` |
| `secret_version_name` | Optional explicit full secret VERSION resource name; overrides the derived path | `string` | `""` |
| `create_bigquery_dataset` | Create the BigQuery dataset | `bool` | `true` |
| `bigquery_dataset` | BigQuery dataset ID | `string` | `vertex_ai_logs` |
| `bigquery_table` | BigQuery table prefix (date-sharded) | `string` | `predictions_` |
| `bigquery_location` | BigQuery dataset location | `string` | `US` |
| `bigquery_log_retention_days` | Log retention in days | `number` | `30` |
| `schedule_cron` | Cloud Scheduler cron expression | `string` | `*/5 * * * *` |
| `function_memory_mb` | Cloud Function memory (MB) | `number` | `512` |
| `function_timeout_seconds` | Cloud Function timeout | `number` | `300` |
| `batch_size` | Concurrent HTTP requests to Stream Security | `number` | `20` |
| `name_prefix` | Resource name prefix | `string` | `streamsec` |
| `enable_request_response_logging` | Enable logging on publisher model via local-exec | `bool` | `true` |
| `vertex_ai_model` | Publisher model name to enable logging on | `string` | `gemini-2.5-flash` |
| `logging_sampling_rate` | Fraction of requests to log (0.0–1.0) | `number` | `1.0` |
| `labels` | Labels applied to all resources | `map(string)` | `managed-by=terraform, component=streamsec-vertex-ai-collection` |

## Outputs

| Name | Description |
|------|-------------|
| `env` | Environment this deployment reports to |
| `collection_url` | Resolved collection base URL the function posts to |
| `function_name` | Deployed Cloud Function name |
| `function_url` | Cloud Function URL (for manual trigger) |
| `service_account_email` | Service account used by the function |
| `scheduler_job_name` | Cloud Scheduler job name |
| `watermark_bucket` | GCS bucket for watermark state |
| `bigquery_dataset_id` | BigQuery dataset ID |
| `bigquery_table_prefix` | BigQuery table prefix |
