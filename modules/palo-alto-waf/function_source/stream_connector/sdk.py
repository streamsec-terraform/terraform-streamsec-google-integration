"""What an adapter is given: the firewall to collect and an Sdk for everything that is not
vendor logic (credentials, HTTP, error reporting, cloud lookups).

An adapter only uses this module and the standard library, so the same adapter file runs on
AWS, Azure and GCP: everything cloud-specific sits behind the Cloud passed to Sdk.
"""

import json
import logging
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Protocol

# The adapter contract version. An adapter declares the HOST_API it was written for; a host
# only runs adapters whose HOST_API it supports (loader.SUPPORTED_HOST_APIS).
HOST_API = 1

log = logging.getLogger("stream_connector")


@dataclass(frozen=True)
class Target:
    """One firewall of the integration. Where its credential lives is not part of it: the
    adapter asks Sdk.credential()."""

    url: str
    resource_id: str | None = None

    @property
    def instance_id(self):
        return self.resource_id or self.url


class CredentialError(Exception):
    pass


class HttpError(Exception):
    """The device answered with an HTTP error status."""

    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body[:200]}")
        self.status = status
        self.body = body


class NetworkError(Exception):
    """The device could not be reached (DNS, refused, TLS, timeout)."""


class Cloud(Protocol):
    def get_secret(self, ref: str, name: str | None) -> str | dict: ...

    def instance_id_for_ip(self, ip: str) -> str | None: ...


class Http:
    """HTTP to one device. TLS is not verified by default: appliances use self-signed
    certificates. `headers` go on every request; set the auth header here once known."""

    def __init__(self, base_url, headers=None, timeout=30, verify_tls=False):
        self.base_url = base_url.rstrip("/")
        self.headers = dict(headers or {})
        self.timeout = timeout
        self._context = None if verify_tls else ssl._create_unverified_context()

    def request(self, method, path, params=None, body=None, headers=None):
        """Send a request and return the response body (bytes).

        `path` is appended to base_url as it is (it may carry its own query string);
        `params` are URL-encoded and appended; `body` is sent as JSON; `headers` are added to
        this request only."""
        url = self.base_url + path
        if params:
            url = f"{url}{'&' if '?' in url else '?'}{urllib.parse.urlencode(params)}"
        headers = {**self.headers, **(headers or {})}
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        # Never log headers or bodies: they carry the credential.
        log.debug("%s %s", method, urllib.parse.urlsplit(url).path)
        try:
            with urllib.request.urlopen(request, context=self._context, timeout=self.timeout) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            raise HttpError(e.code, e.read().decode("utf-8", "replace")) from None
        except urllib.error.URLError as e:
            raise NetworkError(f"{method} {urllib.parse.urlsplit(url).path}: {e.reason}") from None

    def get_json(self, path, params=None):
        return json.loads(self.request("GET", path, params=params))

    def get_text(self, path, params=None):
        return self.request("GET", path, params=params).decode("utf-8")

    def post_json(self, path, body):
        return json.loads(self.request("POST", path, body=body))


class Sdk:
    """Services for collecting one firewall. The host builds one per firewall."""

    def __init__(self, cloud, report_error, entry):
        self._cloud = cloud
        self._report_error = report_error
        self._entry = entry  # the integration entry; carries the secret reference or an inline token

    def credential(self):
        """The firewall's credential: the secret its entry references (a dict for a JSON
        secret, else a str) or, for older integrations, the entry's inline token."""
        ref = self._entry.get("api_key")
        if ref:
            try:
                value = self._cloud.get_secret(ref, self._entry.get("secret_name"))
            except Exception as e:
                raise CredentialError(f"could not read the firewall's secret {ref}: {e}") from None
        else:
            value = self._entry.get("token", "")
        if not value:
            raise CredentialError("the firewall has no credential (empty secret, or no secret and no token)")
        return value

    def http(self, base_url, headers=None, timeout=30, verify_tls=False):
        return Http(base_url, headers=headers, timeout=timeout, verify_tls=verify_tls)

    def report_error(self, message):
        """Send an error to the Stream backend (shown on the integration)."""
        self._report_error(message)

    def instance_id_for_ip(self, ip):
        """The cloud instance that owns this private IP, if the cloud can tell."""
        return self._cloud.instance_id_for_ip(ip)

    def tcp_port_open(self, host, port, timeout=3):
        try:
            with socket.create_connection((host, port), timeout=timeout):
                log.info("TCP port %s is open on %s", port, host)
                return True
        except OSError:
            log.error("TCP port %s is not open on %s", port, host)
            return False
