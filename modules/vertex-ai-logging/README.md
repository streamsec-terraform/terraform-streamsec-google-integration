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
- Stream Security API token stored in Secret Manager (default secret name: `stream-security-collection-token`)
- Required GCP APIs are enabled automatically by the module

## Usage

```hcl
module "vertex_ai_logging" {
  source = "./modules/vertex-ai-logging"

  project_id = "my-gcp-project"
  region     = "us-central1"

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

Check that the scheduled trigger is firing correctly.

```bash
gcloud scheduler jobs describe streamsec-vertex-ai-poll \
  --project=my-gcp-project \
  --location=us-central1

# Check recent execution logs
gcloud functions logs read streamsec-vertex-ai-collector \
  --project=my-gcp-project \
  --region=us-central1 \
  --limit=20
```

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `project_id` | GCP project ID | `string` | — |
| `region` | GCP region | `string` | `us-central1` |
| `secret_name` | Secret Manager secret ID for the API token | `string` | `stream-security-collection-token` |
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
| `function_name` | Deployed Cloud Function name |
| `function_url` | Cloud Function URL (for manual trigger) |
| `service_account_email` | Service account used by the function |
| `scheduler_job_name` | Cloud Scheduler job name |
| `watermark_bucket` | GCS bucket for watermark state |
| `bigquery_dataset_id` | BigQuery dataset ID |
| `bigquery_table_prefix` | BigQuery table prefix |
