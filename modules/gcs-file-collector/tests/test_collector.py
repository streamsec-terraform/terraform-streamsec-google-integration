"""Tests for the gcs-file-collector function.

Storage is faked (FakeStorageClient); the collection endpoint is a real HTTP server on
localhost, so the request the function sends is the request Stream would receive.
"""
import base64
import gzip
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from cloudevents.http import CloudEvent
from google.api_core.exceptions import NotFound

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "function_source"))
import main  # noqa: E402

AUDIT_LOG = gzip.compress(b'{"action":"repo.create","actor":"octocat"}\n{"action":"org.add_member"}\n')


class FakeBlob:
    def __init__(self, objects, bucket, name, generation):
        self.objects, self.key, self.generation = objects, (bucket, name), generation

    def download_as_bytes(self, raw_download=False):
        if self.key not in self.objects:
            raise NotFound("No such object")
        stored, generation = self.objects[self.key]
        if self.generation is not None and self.generation != generation:
            raise NotFound("No such object generation")
        # Cloud Storage decompresses an object stored with Content-Encoding: gzip unless the
        # client asks for the raw bytes.
        return stored if raw_download else gzip.decompress(stored)


class FakeBucket:
    def __init__(self, objects, name):
        self.objects, self.name = objects, name

    def blob(self, name, generation=None):
        return FakeBlob(self.objects, self.name, name, generation)


class FakeStorageClient:
    def __init__(self):
        self.objects = {}  # (bucket, name) -> (stored bytes, generation)

    def bucket(self, name):
        return FakeBucket(self.objects, name)


class Collection:
    """A collection endpoint answering every POST with `status` and recording what it got."""

    def __init__(self):
        self.status = 200
        self.requests = []
        collection = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                collection.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                self.send_response(collection.status)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def storage_client(monkeypatch):
    client = FakeStorageClient()
    monkeypatch.setattr(main, "get_storage_client", lambda: client)
    return client


@pytest.fixture
def collection(monkeypatch):
    endpoint = Collection()
    monkeypatch.setenv("API_URL", endpoint.url + "/")
    monkeypatch.setenv("API_URL_SUFFIX", "github-audit")
    monkeypatch.setenv("API_TOKEN", "collection-token")
    yield endpoint
    endpoint.close()


def object_finalized(name, bucket="audit-logs", generation="1730700000000001"):
    return CloudEvent(
        {"type": "google.cloud.storage.object.v1.finalized", "source": f"//storage.googleapis.com/projects/_/buckets/{bucket}"},
        {"bucket": bucket, "name": name, "generation": generation},
    )


def put(storage_client, name, data, bucket="audit-logs", generation=1730700000000001):
    storage_client.objects[(bucket, name)] = (data, generation)


def test_forwards_a_gzip_object_whole_to_the_collection_endpoint(storage_client, collection):
    put(storage_client, "2026/11/04/10/00/a1.json.gz", AUDIT_LOG)

    main.collect(object_finalized("2026/11/04/10/00/a1.json.gz"))

    [request] = collection.requests
    assert request["path"] == "/api/v1/collection/github-audit"
    assert request["headers"]["X-Lightlytics-Token"] == "collection-token"
    assert request["headers"]["Content-Type"] == "application/json"
    assert base64.b64decode(json.loads(request["body"])["data"]) == AUDIT_LOG


def test_sends_the_stored_bytes_of_an_object_cloud_storage_would_decompress(storage_client, collection):
    # The endpoint unpacks a payload only when it is gzip; a transcoded copy would be read as
    # one webhook event.
    put(storage_client, "a1.json.gz", AUDIT_LOG)

    main.collect(object_finalized("a1.json.gz"))

    assert json.loads(collection.requests[0]["body"])["data"].startswith("H4sI")


def test_reads_the_generation_the_event_is_about(storage_client, collection):
    put(storage_client, "a1.json.gz", AUDIT_LOG, generation=1730700000000002)

    main.collect(object_finalized("a1.json.gz", generation="1730700000000001"))

    assert collection.requests == []


def test_skips_an_object_that_is_not_gzip(storage_client, collection):
    put(storage_client, "github-stream-check.txt", b"GitHub audit log stream test")

    main.collect(object_finalized("github-stream-check.txt"))

    assert collection.requests == []


def test_skips_gzip_magic_that_is_not_deflate(storage_client, collection):
    # The endpoint unpacks a payload only when its base64 starts with "H4sI": 1f 8b 08.
    put(storage_client, "odd.gz", b"\x1f\x8b\x00" + AUDIT_LOG[3:])

    main.collect(object_finalized("odd.gz"))

    assert collection.requests == []


def test_skips_an_object_deleted_before_it_was_read(storage_client, collection):
    main.collect(object_finalized("gone.json.gz"))

    assert collection.requests == []


@pytest.mark.parametrize("status", [500, 502, 503, 408, 429])
def test_raises_on_a_failure_worth_retrying_so_eventarc_redelivers(storage_client, collection, status):
    put(storage_client, "a1.json.gz", AUDIT_LOG)
    collection.status = status

    with pytest.raises(main.RetryableDeliveryError, match=str(status)):
        main.collect(object_finalized("a1.json.gz"))


@pytest.mark.parametrize("status", [400, 401, 403, 413])
def test_does_not_retry_a_failure_that_would_repeat(storage_client, collection, status, caplog):
    put(storage_client, "a1.json.gz", AUDIT_LOG)
    collection.status = status

    main.collect(object_finalized("a1.json.gz"))

    assert len(collection.requests) == 1
    assert f"gs://audit-logs/a1.json.gz returned {status}" in caplog.text


def test_raises_when_the_endpoint_cannot_be_reached(storage_client, collection, monkeypatch):
    put(storage_client, "a1.json.gz", AUDIT_LOG)
    collection.close()

    with pytest.raises(main.RetryableDeliveryError, match="a1.json.gz"):
        main.collect(object_finalized("a1.json.gz"))
