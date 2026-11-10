"""Stream Security file collector for Cloud Storage (Cloud Functions 2nd gen).

The GCP counterpart of the AWS s3-file-collector and the Azure file collector: every object
written to the bucket is posted whole, as {"data": base64(bytes)}, to
<API_URL>/api/v1/collection/<API_URL_SUFFIX>. GitHub Enterprise streams its audit log as
gzipped NDJSON objects, and /collection/github-audit unpacks a payload only when it is gzip
(anything else is read as a single webhook event), so an object that is not gzip is skipped.

Triggered by Eventarc on google.cloud.storage.object.v1.finalized. Raising makes Eventarc
redeliver the event with backoff for up to 24 hours.

Runtime env:
  API_URL         Stream tenant base URL, e.g. https://app.streamsec.io
  API_URL_SUFFIX  Collection endpoint, e.g. github-audit
  API_TOKEN       Stream collection token (mounted from Secret Manager)
"""

import base64
import logging

# Cloud Functions gen2 leaves the root logger at WARNING, so logging.info would be dropped.
logging.basicConfig(level=logging.INFO)

import os

import functions_framework
import requests
from google.api_core.exceptions import NotFound
from google.cloud import storage

# gzip with deflate, what the endpoint's "H4sI" check accepts
GZIP_MAGIC = b"\x1f\x8b\x08"
REQUEST_TIMEOUT_SECONDS = 30
# Client errors that can succeed on a later delivery; any other 4xx (a revoked token, a
# payload too large) would fail the same way every time.
RETRYABLE_CLIENT_STATUSES = {408, 429}

_storage_client = None


class RetryableDeliveryError(Exception):
    """Raised so that Eventarc redelivers the event."""


def get_storage_client():
    global _storage_client
    if _storage_client is None:
        _storage_client = storage.Client()
    return _storage_client


def collection_url():
    return f"{os.environ['API_URL'].rstrip('/')}/api/v1/collection/{os.environ['API_URL_SUFFIX'].strip('/')}"


@functions_framework.cloud_event
def collect(cloud_event):
    bucket, name, generation = cloud_event.data["bucket"], cloud_event.data["name"], cloud_event.data.get("generation")
    location = f"gs://{bucket}/{name}"

    # The generation the event is about: an object overwritten since is a later event's.
    blob = get_storage_client().bucket(bucket).blob(name, generation=int(generation) if generation else None)
    try:
        # The stored bytes: an object written with Content-Encoding: gzip is otherwise
        # decompressed on download, and would then be skipped as not gzip.
        content = blob.download_as_bytes(raw_download=True)
    except NotFound:
        logging.warning("%s no longer exists; skipping", location)
        return

    if not content.startswith(GZIP_MAGIC):
        logging.info("%s is not gzip; skipping", location)
        return

    try:
        response = requests.post(
            collection_url(),
            json={"data": base64.b64encode(content).decode("ascii")},
            headers={"X-Lightlytics-Token": os.environ["API_TOKEN"]},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.RequestException as e:
        raise RetryableDeliveryError(f"Sending {location} failed: {e}") from e

    if response.status_code >= 500 or response.status_code in RETRYABLE_CLIENT_STATUSES:
        raise RetryableDeliveryError(f"Sending {location} returned {response.status_code}")
    if not response.ok:
        logging.error("Sending %s returned %s; not retrying", location, response.status_code)
        return
    logging.info("Sent %s (%d bytes): %s", location, len(content), response.status_code)
