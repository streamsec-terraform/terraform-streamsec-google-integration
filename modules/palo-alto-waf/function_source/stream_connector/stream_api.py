"""The Stream backend, as the connector sees it: which firewalls to collect, the current
adapter release, where errors and the payload go."""

import gzip
import json
import logging
import urllib.error
import urllib.request

log = logging.getLogger("stream_connector")

GZIP_THRESHOLD_BYTES = 512 * 1024  # 512 KB


class StreamApi:
    def __init__(self, api_url, token, timeout=30):
        self.api_url = api_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def _call(self, method, path, body=None, headers=None):
        request = urllib.request.Request(f"{self.api_url}{path}", data=body, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json", **(headers or {})})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return json.loads(response.read() or b"null")

    def get_firewalls(self):
        """(vendor, entries): the integration's type and its firewalls."""
        data = (self._call("GET", "/api/accounts/waf/firewalls") or {}).get("data") or {}
        return data.get("type", ""), data.get("firewalls", [])

    def get_adapter_release(self, vendor):
        """The current signed adapter release for a vendor ({"source", "signature"}, both
        base64), or None when the backend has none."""
        try:
            data = (self._call("GET", f"/api/accounts/waf/adapters/{vendor}") or {}).get("data")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise
        return data or None

    def report_error(self, message):
        try:
            self._call("POST", "/api/accounts/waf/error_report", json.dumps({"error_message": message}).encode())
        except Exception as e:
            log.error("Error reporting to backend: %s", e)

    def send(self, payload):
        """POST the payload to the waf-audit collection: {"data": <payload as a JSON string>},
        gzipped from GZIP_THRESHOLD_BYTES."""
        body = json.dumps({"data": json.dumps(payload)}).encode("utf-8")
        headers = {"X-Lightlytics-Token": self.token}
        if len(body) >= GZIP_THRESHOLD_BYTES:
            body = gzip.compress(body)
            headers["Content-Encoding"] = "gzip"
        log.info("Sending firewall details: %d bytes%s", len(body), " (gzip)" if "Content-Encoding" in headers else "")
        self._call("POST", "/api/v1/collection/waf-audit", body, headers)
