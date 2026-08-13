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
from datetime import datetime, timedelta, timezone

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

# How far BELOW the watermark each poll re-reads. logging_time is event time and rows land in
# BigQuery later, so a cursor anchored exactly at the watermark misses any row that becomes
# visible with an earlier event time than one already committed. Size from the observed
# vertex_ingestion_lag_seconds tail (roughly 2x p99).
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", "15"))

STATE_BLOB = "watermark/collector_state.json"
# Pre-lookback layout: the watermark alone, as bare text. Read once to migrate, never written.
LEGACY_WATERMARK_BLOB = "watermark/last_processed_timestamp.txt"
DEFAULT_WATERMARK = "2000-01-01T00:00:00Z"
# Ceiling on remembered request IDs. This map only suppresses duplicate sends -- it is not a
# delivery ledger -- so overflowing it costs duplicates, never dropped rows.
MAX_RECENT_IDS = 50000

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


def parse_iso_timestamp(value) -> datetime:
    """Parse an ISO-8601 timestamp, tolerating the trailing-Z form and naive values."""
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def to_utc_datetime(value):
    """Coerce a BigQuery TIMESTAMP (or ISO string) to an aware UTC datetime, or None."""
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if not value:
        return None
    try:
        return parse_iso_timestamp(value)
    except (ValueError, TypeError):
        return None


def request_key(row: dict) -> str:
    """Dedup key for a row. Empty when the row carries no request_id.

    A row without one is never suppressed and never remembered, so it may be re-sent on the
    next sweep. Duplicates are safe; guessing an identity would not be.
    """
    value = row.get("request_id")
    return str(value) if value else ""


def normalize_state(state) -> dict:
    """Coerce whatever is in the state blob into the expected shape."""
    if not isinstance(state, dict):
        return {"watermark": DEFAULT_WATERMARK, "last_request_id": "", "recent": {}}
    recent = state.get("recent")
    return {
        "watermark": str(state.get("watermark") or DEFAULT_WATERMARK),
        # Second half of the composite cursor. Empty sorts before every real id, so a state
        # written by an older version resumes at the start of its watermark second.
        "last_request_id": str(state.get("last_request_id") or ""),
        "recent": recent if isinstance(recent, dict) else {},
    }


def is_after_cursor(row: dict, watermark_ts: datetime, last_request_id: str) -> bool:
    """Whether a row sorts strictly after the composite cursor."""
    event_time = to_utc_datetime(row.get("logging_time"))
    if event_time is None:
        return False
    if event_time > watermark_ts:
        return True
    return event_time == watermark_ts and request_key(row) > last_request_id


def sort_key(row: dict, fallback: datetime):
    """Ascending (logging_time, request_id) ordering, matching the query's ORDER BY."""
    return (to_utc_datetime(row.get("logging_time")) or fallback, request_key(row))


def read_state(storage_client: storage.Client) -> tuple[dict, int]:
    """Load collector state along with the GCS generation it was read at.

    The generation goes back to write_state as if_generation_match, so a concurrent invocation
    cannot silently clobber this one's progress. Generation 0 means "must not exist yet".
    """
    bucket = storage_client.bucket(STATE_BUCKET)
    blob = bucket.blob(STATE_BLOB)

    if blob.exists():
        blob.reload()
        return normalize_state(json.loads(blob.download_as_text())), blob.generation

    # Migration from the pre-lookback layout: seed the watermark, start with an empty cache.
    # The first poll after upgrading re-reads one lookback window and may re-send it, which
    # downstream dedupes on request_id.
    # Both remaining paths go through normalize_state so every caller sees the full shape,
    # rather than only the blob-exists path being normalized.
    legacy = bucket.blob(LEGACY_WATERMARK_BLOB)
    if legacy.exists():
        watermark = legacy.download_as_text().strip()
        print(f"Migrating legacy watermark ({watermark}) to {STATE_BLOB}")
        return normalize_state({"watermark": watermark}), 0

    return normalize_state(None), 0


def write_state(storage_client: storage.Client, state: dict, generation: int):
    """Persist state, refusing the write if another invocation moved it first.

    A precondition failure raises, failing the poll so Cloud Scheduler retries. That is the
    right outcome: the other invocation's progress stands and this one re-reads from it.
    """
    blob = storage_client.bucket(STATE_BUCKET).blob(STATE_BLOB)
    blob.upload_from_string(
        json.dumps(state),
        content_type="application/json",
        if_generation_match=generation,
    )


def prune_recent(recent: dict, cutoff: datetime) -> dict:
    """Drop remembered request IDs that can no longer be re-queried.

    Anything older than the sweep floor will never come back in a query, so remembering it
    serves no purpose. Entries are also capped: the cache exists to avoid re-sending, not to
    guarantee it, so shedding the oldest costs duplicates rather than correctness.
    """
    kept = {}
    for key, seen_at in recent.items():
        timestamp = to_utc_datetime(seen_at)
        if timestamp and timestamp > cutoff:
            kept[key] = seen_at

    if len(kept) > MAX_RECENT_IDS:
        print(
            f"recent-id cache over cap ({len(kept)} > {MAX_RECENT_IDS}); dropping oldest — "
            "some already-delivered rows may be re-sent and deduped downstream"
        )
        newest = sorted(kept.items(), key=lambda item: item[1], reverse=True)[:MAX_RECENT_IDS]
        kept = dict(newest)

    return kept


def query_vertex_ai_logs(
    bq_client: bigquery.Client, floor: str, watermark: str, last_request_id: str
) -> list[dict]:
    """Fetch one poll's worth of rows: everything past the cursor, plus a catch-up sweep.

    Two ranges in one job, each with its own LIMIT, because they fail differently:

    `forward` reads strictly past the composite cursor (logging_time, request_id). The
    request_id tiebreak is what stops a group of rows sharing one logging_time from being
    truncated by the LIMIT and then skipped — the cursor resumes mid-group instead of jumping
    to the next timestamp.

    `sweep` re-reads the lookback window BEHIND the cursor, catching rows that became visible
    after the cursor had already moved past their event time. It must have its own LIMIT: with
    a single combined query the sweep's already-delivered rows sort first, consume the whole
    limit, and starve forward progress entirely. Splitting them guarantees the forward range
    always gets its full budget no matter how busy the sweep window is.
    """
    table_ref = f"`{GCP_PROJECT_ID}.{BIGQUERY_DATASET}.{BIGQUERY_TABLE}*`"
    columns = """
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
    """

    # IFNULL keeps rows with a NULL request_id comparable: a NULL comparison yields NULL, which
    # would silently drop such a row from the forward range at exactly the cursor timestamp.
    query = f"""
        WITH forward AS (
            SELECT {columns}
            FROM {table_ref}
            WHERE logging_time > @watermark
               OR (logging_time = @watermark AND IFNULL(request_id, '') > @last_request_id)
            ORDER BY logging_time ASC, IFNULL(request_id, '') ASC
            LIMIT @max_rows
        ),
        sweep AS (
            SELECT {columns}
            FROM {table_ref}
            WHERE logging_time > @floor
              AND (logging_time < @watermark
                   OR (logging_time = @watermark AND IFNULL(request_id, '') <= @last_request_id))
            ORDER BY logging_time DESC, IFNULL(request_id, '') DESC
            LIMIT @max_rows
        )
        SELECT * FROM forward
        UNION ALL
        SELECT * FROM sweep
    """

    # With lookback disabled floor == watermark, so the sweep predicate is unsatisfiable and
    # the query degrades to the forward range alone.
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("floor", "TIMESTAMP", floor),
            bigquery.ScalarQueryParameter("watermark", "TIMESTAMP", watermark),
            bigquery.ScalarQueryParameter("last_request_id", "STRING", last_request_id),
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

    state, generation = read_state(storage_client)
    watermark = state["watermark"]
    watermark_ts = parse_iso_timestamp(watermark)
    last_request_id = state["last_request_id"]
    recent = state["recent"]

    # Sweep from BELOW the cursor as well as past it, so rows that became visible late -- with
    # an event time earlier than one already committed -- are still picked up. `recent` then
    # suppresses whatever was already delivered from that re-read window.
    floor_ts = watermark_ts - timedelta(minutes=LOOKBACK_MINUTES)
    print(
        f"Polling Vertex AI logs since {floor_ts.isoformat()} "
        f"(cursor {watermark}/{last_request_id or '-'}, "
        f"lookback {LOOKBACK_MINUTES}m, {len(recent)} ids cached)"
    )

    rows = query_vertex_ai_logs(
        bq_client, floor_ts.isoformat(), watermark, last_request_id
    )
    if not rows:
        print("No rows in window")
        return {"status": "ok", "rows_processed": 0, "new_watermark": watermark}, 200

    # Rows with no request_id have an empty key, which is never stored in `recent`, so they
    # always fall through as fresh — re-sent rather than silently suppressed.
    fresh = [row for row in rows if request_key(row) not in recent]
    fresh.sort(key=lambda row: sort_key(row, floor_ts))
    suppressed = len(rows) - len(fresh)
    print(f"Found {len(rows)} rows in window; {len(fresh)} to send, {suppressed} already delivered")

    if not fresh:
        return {
            "status": "ok",
            "rows_processed": 0,
            "rows_suppressed": suppressed,
            "new_watermark": watermark,
        }, 200

    log_ingestion_lag(fresh)

    api_token = get_api_token()
    audit_logs = [row_to_gcp_audit_log(row) for row in fresh]

    delivered = send_logs(audit_logs, api_token)
    sent_count = sum(delivered)
    failed_count = len(fresh) - sent_count

    # The cursor only tracks rows past itself. Rows the sweep found behind it are catch-up and
    # must not move it -- they are behind it by definition, and letting them advance it would
    # drag the floor forward over ground still being back-filled.
    forward = [
        (row, ok)
        for row, ok in zip(fresh, delivered)
        if is_after_cursor(row, watermark_ts, last_request_id)
    ]
    committed = committed_prefix_length([ok for _, ok in forward])
    if committed:
        last_committed = forward[committed - 1][0]
        new_watermark = to_iso_timestamp(last_committed.get("logging_time"))
        new_last_request_id = request_key(last_committed)
    else:
        new_watermark, new_last_request_id = watermark, last_request_id

    # Remember what was delivered so the next sweep does not re-send it, then forget whatever
    # has fallen below the new floor and can never be re-queried.
    for row, ok in zip(fresh, delivered):
        key = request_key(row)
        if ok and key:
            recent[key] = to_iso_timestamp(row.get("logging_time"))

    state["watermark"] = new_watermark
    state["last_request_id"] = new_last_request_id
    state["recent"] = prune_recent(
        recent, parse_iso_timestamp(new_watermark) - timedelta(minutes=LOOKBACK_MINUTES)
    )
    write_state(storage_client, state, generation)

    elapsed = time.time() - start_time
    print(
        f"Done: {sent_count}/{len(fresh)} logs sent in {elapsed:.1f}s, committed={committed}, "
        f"cursor={new_watermark}/{new_last_request_id or '-'}, cached={len(state['recent'])}"
    )

    body = {
        "status": "ok" if failed_count == 0 else "partial",
        "rows_processed": sent_count,
        "rows_failed": failed_count,
        "rows_suppressed": suppressed,
        "rows_committed": committed,
        "lookback_minutes": LOOKBACK_MINUTES,
        "new_watermark": new_watermark,
        "new_last_request_id": new_last_request_id,
    }

    # Nothing at all got through despite having rows to send: fail loudly so Scheduler retries
    # and it surfaces in monitoring instead of looking like a clean run. Note this is keyed on
    # sent_count, not `committed` -- a poll that delivers only catch-up rows from below the
    # watermark legitimately commits nothing and is still a success.
    if sent_count == 0:
        return body, 500

    return body, 200
