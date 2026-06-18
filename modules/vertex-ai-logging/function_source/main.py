"""
Stream Security — GCP Vertex AI BigQuery Log Collector

Polls BigQuery for new Vertex AI request-response logging rows,
converts them to GCP audit log JSON format, and POSTs to ms_collection's
/collection/gcp-audit-log endpoint.
"""

import json
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import functions_framework
import requests
from google.cloud import bigquery, secretmanager, storage

GCP_PROJECT_ID = os.environ["GCP_PROJECT_ID"]
BIGQUERY_DATASET = os.environ["BIGQUERY_DATASET"]
BIGQUERY_TABLE = os.environ["BIGQUERY_TABLE"]
API_URL = os.environ["API_URL"]
COLLECTION_PATH = "/api/v1/collection/gcp-audit-log"
COLLECTION_URL = f"{API_URL.rstrip('/')}{COLLECTION_PATH}"
STATE_BUCKET = os.environ["STATE_BUCKET"]
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "20"))
# Full Secret Manager secret version resource name, e.g.
#   projects/<p>/secrets/<s>/versions/latest                      (global)
#   projects/<p>/locations/<r>/secrets/<s>/versions/latest        (regional)
# Passed verbatim so the secret can be owned/shared by another module (real-time-events).
SECRET_NAME = os.environ["SECRET_NAME"]

WATERMARK_BLOB = "watermark/last_processed_timestamp.txt"
MAX_ROWS_PER_POLL = 10000
REQUEST_TIMEOUT_SECONDS = 30


def get_api_token() -> str:
    # SECRET_NAME is the full version resource name. Regional secrets must be read via a
    # regional endpoint; global secrets via the default endpoint.
    region = extract_region(SECRET_NAME)
    if region:
        client = secretmanager.SecretManagerServiceClient(
            client_options={"api_endpoint": f"secretmanager.{region}.rep.googleapis.com"}
        )
    else:
        client = secretmanager.SecretManagerServiceClient()
    response = client.access_secret_version(request={"name": SECRET_NAME})
    return response.payload.data.decode("utf-8")


def read_watermark(storage_client: storage.Client) -> str:
    bucket = storage_client.bucket(STATE_BUCKET)
    blob = bucket.blob(WATERMARK_BLOB)
    if blob.exists():
        return blob.download_as_text().strip()
    return "2000-01-01T00:00:00Z"


def write_watermark(storage_client: storage.Client, timestamp: str):
    bucket = storage_client.bucket(STATE_BUCKET)
    blob = bucket.blob(WATERMARK_BLOB)
    blob.upload_from_string(timestamp, content_type="text/plain")


def query_vertex_ai_logs(bq_client: bigquery.Client, watermark: str) -> list[dict]:
    table_ref = f"`{GCP_PROJECT_ID}.{BIGQUERY_DATASET}.{BIGQUERY_TABLE}*`"
    query = f"""
        SELECT
            logging_time,
            endpoint,
            deployed_model_id,
            model,
            model_version,
            api_method,
            full_request,
            full_response,
            request_id,
            metadata
        FROM {table_ref}
        WHERE logging_time > @watermark
        ORDER BY logging_time ASC
        LIMIT @max_rows
    """

    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("watermark", "TIMESTAMP", watermark),
            bigquery.ScalarQueryParameter("max_rows", "INT64", MAX_ROWS_PER_POLL),
        ]
    )

    results = bq_client.query(query, job_config=job_config)
    return [dict(row) for row in results]


def extract_model_id(model_resource_name: str) -> str:
    """Extract model short name from full resource path.

    Input:  projects/my-proj/locations/us-central1/publishers/google/models/gemini-2.5-flash
    Output: gemini-2.5-flash
    """
    if not model_resource_name:
        return "unknown"
    parts = model_resource_name.rstrip("/").split("/")
    if "models" in parts:
        idx = parts.index("models")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    return parts[-1] if parts else "unknown"


def extract_region(endpoint_or_model: str) -> str:
    """Extract region from a resource path containing locations/{region}/."""
    for path in [endpoint_or_model or ""]:
        parts = path.split("/")
        if "locations" in parts:
            idx = parts.index("locations")
            if idx + 1 < len(parts):
                return parts[idx + 1]
    return "unknown"


def extract_caller_from_metadata(metadata) -> str:
    """Extract caller identity from metadata if available."""
    if not metadata or not isinstance(metadata, dict):
        return ""
    return metadata.get("callerIdentity", "") or metadata.get("caller", "")


def safe_json_string(payload) -> str:
    """Safely convert a payload (string, dict, or None) to a JSON string."""
    if payload is None:
        return ""
    if isinstance(payload, str):
        return payload
    return json.dumps(payload, default=str)


def row_to_gcp_audit_log(row: dict) -> dict:
    """Convert a Vertex AI BigQuery logging row to a GCP audit log JSON object.

    The output is a standard GCP Cloud Audit Log envelope (protoPayload, logName, etc.)
    that the /collection/gcp-audit-log handler and downstream GCP identity parser expect.

    Extra top-level fields (modelId, input, output) are included so the downstream
    iam_log_processor can extract model hints, request/response content, and tool
    declarations from the raw JSON.
    """
    metadata = row.get("metadata") or {}

    caller_identity = extract_caller_from_metadata(metadata)
    model_resource = row.get("model", "") or row.get("endpoint", "") or ""
    model_id = extract_model_id(model_resource)
    region = extract_region(model_resource)

    api_method = row.get("api_method", "") or ""
    method_name = f"aiplatform.{api_method}" if api_method else "aiplatform.endpoints.predict"

    logging_time = row.get("logging_time")
    if isinstance(logging_time, datetime):
        event_time = logging_time.isoformat()
    else:
        event_time = str(logging_time) if logging_time else datetime.now(timezone.utc).isoformat()

    request_payload = safe_json_string(row.get("full_request"))
    response_payload = safe_json_string(row.get("full_response"))

    return {
        "logName": f"projects/{GCP_PROJECT_ID}/logs/cloudaudit.googleapis.com%2Fdata_access",
        "protoPayload": {
            "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
            "methodName": method_name,
            "serviceName": "aiplatform.googleapis.com",
            "authenticationInfo": {
                "principalEmail": caller_identity,
            },
            "resourceName": model_resource,
            "resourceLocation": {
                "currentLocations": [region],
            },
            "request": {
                "model": model_resource,
            },
        },
        "resource": {
            "type": "aiplatform.googleapis.com/Endpoint",
            "labels": {
                "project_id": GCP_PROJECT_ID,
            },
        },
        "timestamp": event_time,
        "severity": "INFO",
        "modelId": model_id,
        "modelResource": model_resource,
        "deployedModelId": row.get("deployed_model_id", "") or "",
        "modelVersionId": row.get("model_version", "") or "",
        "input": {"inputBody": request_payload},
        "output": {"outputBody": response_payload},
    }


def send_log(session: requests.Session, log: dict) -> bool:
    """POST a single GCP audit log JSON object to ms_collection."""
    response = session.post(COLLECTION_URL, json=log, timeout=REQUEST_TIMEOUT_SECONDS)
    response.raise_for_status()
    return True


def send_logs(logs: list[dict], api_token: str) -> int:
    """Send logs concurrently using a thread pool. Returns the number of logs sent."""
    session = requests.Session()
    session.headers.update({
        "Content-Type": "application/json",
        "X-Lightlytics-Token": api_token,
    })

    sent = 0
    failed = 0

    with ThreadPoolExecutor(max_workers=BATCH_SIZE) as executor:
        futures = {executor.submit(send_log, session, log): i for i, log in enumerate(logs)}
        for future in as_completed(futures):
            try:
                future.result()
                sent += 1
            except Exception as e:
                failed += 1
                if failed <= 5:
                    print(f"Failed to send log {futures[future]}: {e}")

    if failed:
        print(f"Warning: {failed}/{len(logs)} logs failed to send")

    return sent


@functions_framework.http
def handler(request):
    """Cloud Function entry point — triggered by Cloud Scheduler every 5 minutes."""
    start_time = time.time()

    storage_client = storage.Client(project=GCP_PROJECT_ID)
    bq_client = bigquery.Client(project=GCP_PROJECT_ID)

    watermark = read_watermark(storage_client)
    print(f"Polling Vertex AI logs since {watermark}")

    rows = query_vertex_ai_logs(bq_client, watermark)
    if not rows:
        print("No new rows found")
        return {"status": "ok", "rows_processed": 0}, 200

    print(f"Found {len(rows)} new rows")

    api_token = get_api_token()
    audit_logs = [row_to_gcp_audit_log(row) for row in rows]

    sent_count = send_logs(audit_logs, api_token)

    max_timestamp = rows[-1].get("logging_time")
    if isinstance(max_timestamp, datetime):
        new_watermark = max_timestamp.isoformat()
    else:
        new_watermark = str(max_timestamp)

    write_watermark(storage_client, new_watermark)

    elapsed = time.time() - start_time
    print(f"Done: {sent_count} logs sent in {elapsed:.1f}s, watermark={new_watermark}")

    return {"status": "ok", "rows_processed": sent_count, "new_watermark": new_watermark}, 200
