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
# Sentinel extract_region() returns when a resource path carries no locations/ segment.
UNKNOWN_REGION = "unknown"


def get_api_token() -> str:
    # SECRET_NAME is the full version resource name. Regional secrets must be read via a
    # regional endpoint; global secrets via the default endpoint. A global path has no
    # locations/ segment, so extract_region returns its "unknown" sentinel — which must NOT be
    # treated as a region, or the client targets secretmanager.unknown.rep.googleapis.com.
    region = extract_region(SECRET_NAME)
    if region and region != UNKNOWN_REGION:
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
    parts = (endpoint_or_model or "").split("/")
    if "locations" in parts:
        idx = parts.index("locations")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    return UNKNOWN_REGION


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


def to_iso_timestamp(value) -> str:
    """Render a BigQuery TIMESTAMP value as an ISO-8601 string."""
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value)


def log_ingestion_lag(rows: list[dict]):
    """Emit ingestion-lag percentiles for the rows this poll made visible.

    logging_time is event time; a row becomes visible in BigQuery some time later. The MINIMUM
    age across a poll approximates the current ingestion lag — that row showed up almost
    immediately — and the spread across polls is what actually matters, because the watermark
    advances to the newest row seen. Any row lagging more than about a poll interval behind its
    peers is skipped permanently (see issue #43). Sizing that fix needs the observed tail rather
    than a guess, so this measures it before anything is changed.

    Emitted as structured JSON so Cloud Logging parses it into jsonPayload and a log-based
    metric can be built over the fields.
    """
    now = datetime.now(timezone.utc)

    ages = []
    for row in rows:
        event_time = row.get("logging_time")
        if not isinstance(event_time, datetime):
            continue
        # BigQuery returns TIMESTAMP as UTC-aware, but don't let a naive value raise here —
        # this is diagnostics and must never break a poll.
        if event_time.tzinfo is None:
            event_time = event_time.replace(tzinfo=timezone.utc)
        ages.append((now - event_time).total_seconds())

    if not ages:
        return

    ages.sort()

    def percentile(fraction: float) -> float:
        return ages[min(int(len(ages) * fraction), len(ages) - 1)]

    print(json.dumps({
        "metric": "vertex_ingestion_lag_seconds",
        "rows": len(ages),
        "min": round(ages[0], 1),
        "p50": round(percentile(0.50), 1),
        "p95": round(percentile(0.95), 1),
        "max": round(ages[-1], 1),
    }))


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
    event_time = (
        to_iso_timestamp(logging_time) if logging_time else datetime.now(timezone.utc).isoformat()
    )

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


def send_logs(logs: list[dict], api_token: str) -> list[bool]:
    """Send logs concurrently using a thread pool.

    Returns a list of per-log success flags, index-aligned with `logs`, so the caller can tell
    exactly which rows were delivered rather than only how many.
    """
    session = requests.Session()
    session.headers.update({
        "Content-Type": "application/json",
        "X-Lightlytics-Token": api_token,
    })

    delivered = [False] * len(logs)
    failed = 0

    with ThreadPoolExecutor(max_workers=BATCH_SIZE) as executor:
        futures = {executor.submit(send_log, session, log): i for i, log in enumerate(logs)}
        for future in as_completed(futures):
            index = futures[future]
            try:
                future.result()
                delivered[index] = True
            except Exception as e:
                failed += 1
                if failed <= 5:
                    print(f"Failed to send log {index}: {e}")

    if failed:
        print(f"Warning: {failed}/{len(logs)} logs failed to send")

    return delivered


def committed_prefix_length(delivered: list[bool]) -> int:
    """Length of the leading run of successfully delivered logs.

    Rows are queried ORDER BY logging_time ASC, so the watermark may only advance across an
    unbroken prefix of successes. The first failure stops it: everything from that row onward is
    re-queried on the next poll. That trades duplicates (downstream dedupes on request_id) for
    never dropping a row, instead of the reverse.
    """
    count = 0
    for ok in delivered:
        if not ok:
            break
        count += 1
    return count


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
    log_ingestion_lag(rows)

    api_token = get_api_token()
    audit_logs = [row_to_gcp_audit_log(row) for row in rows]

    delivered = send_logs(audit_logs, api_token)
    sent_count = sum(delivered)
    failed_count = len(rows) - sent_count

    # Only advance the watermark across rows we know were delivered, and only across an unbroken
    # leading run of them. Advancing to rows[-1] regardless (as this previously did) skipped every
    # failed row permanently while still returning 200, so Scheduler never retried them.
    committed = committed_prefix_length(delivered)
    if committed:
        new_watermark = to_iso_timestamp(rows[committed - 1].get("logging_time"))
        write_watermark(storage_client, new_watermark)
    else:
        new_watermark = watermark

    elapsed = time.time() - start_time
    print(
        f"Done: {sent_count}/{len(rows)} logs sent in {elapsed:.1f}s, "
        f"committed={committed}, watermark={new_watermark}"
    )

    body = {
        "status": "ok" if failed_count == 0 else "partial",
        "rows_processed": sent_count,
        "rows_failed": failed_count,
        "rows_committed": committed,
        "new_watermark": new_watermark,
    }

    # No forward progress at all despite having rows: report failure so Scheduler retries and the
    # error surfaces in monitoring instead of looking like a clean run.
    if committed == 0:
        return body, 500

    return body, 200
