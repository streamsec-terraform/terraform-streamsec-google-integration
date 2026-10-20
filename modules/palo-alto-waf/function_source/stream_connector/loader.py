"""Picks the adapter to run for a vendor: the backend's current signed release, else the one
built into this package.

A release is the adapter's source file plus an Ed25519 signature over it, made in CI. The
host runs a release only when the signature verifies against a key pinned in this package
(trust.PUBLIC_KEYS), the adapter is for the requested vendor and host contract, and it is
not older than the bundled one. That stops a replayed release older than this deploy; a
replayed release between the bundled version and the latest one is still accepted. Vendor,
host API and version are read from the source before it runs. Anything else is reported and
the bundled adapter runs.
"""

import ast
import base64
import hashlib
import importlib
import linecache
import logging
import sys
import types

from adapters import VENDOR_MODULES
from stream_connector.sdk import HOST_API
from stream_connector.trust import PUBLIC_KEYS

log = logging.getLogger("stream_connector")

SUPPORTED_HOST_APIS = {HOST_API}

_current = {}  # vendor -> (sha256, adapter): a warm container reuses the loaded release


class AdapterRejected(Exception):
    pass


def select_adapter(vendor, api, updates_enabled=True):
    bundled = _bundled(vendor)
    if bundled is None:
        # A package serves the one vendor it was built for; another vendor is a redeploy.
        raise AdapterRejected(f"this connector was not built for {vendor!r} integrations")
    if not updates_enabled or not PUBLIC_KEYS:
        return bundled
    try:
        release = api.get_adapter_release(vendor)
        if release is None:
            return bundled
        return load_release(vendor, release["source"], release["signature"], min_version=bundled.VERSION)
    except Exception as e:
        log.error("Adapter release for %s not used, running the bundled v%s: %s", vendor, bundled.VERSION, e)
        api.report_error(f"Adapter release for {vendor} not used, running the bundled v{bundled.VERSION}: {e}")
        return bundled


def load_release(vendor, source_b64, signature_b64, min_version):
    source = base64.b64decode(source_b64)
    _verify(source, base64.b64decode(signature_b64))
    digest = hashlib.sha256(source).hexdigest()
    current = _current.get(vendor)
    if current and current[0] == digest:
        return current[1]
    _check_declared(source, vendor, min_version)

    # A module name per release, so a new release never mixes with the previous one's
    # module state; registered in sys.modules because dataclasses and typing look it up there.
    name = f"stream_adapter_{vendor.replace('-', '_')}_{digest[:16]}"
    filename = f"<adapter {vendor} {digest[:16]}>"
    linecache.cache[filename] = (len(source), None, source.decode("utf-8").splitlines(True), filename)
    module = types.ModuleType(name)
    module.__file__ = filename
    sys.modules[name] = module
    try:
        exec(compile(source, filename, "exec"), module.__dict__)
        adapter = _checked(getattr(module, "ADAPTER", None), vendor)
        if adapter.VERSION < min_version:
            raise AdapterRejected(f"release v{adapter.VERSION} is older than the bundled v{min_version}")
    except BaseException:
        del sys.modules[name]
        raise

    if current:
        sys.modules.pop(current[1].__module__, None)
    _current[vendor] = (digest, adapter)
    log.info("Loaded adapter release %s v%s (sha256 %s)", vendor, adapter.VERSION, digest[:16])
    return adapter


def _check_declared(source, vendor, min_version):
    """VENDOR, HOST_API and VERSION of the ADAPTER class, read without running the source."""
    try:
        tree = ast.parse(source)
        name = next(n.value.id for n in tree.body if isinstance(n, ast.Assign) and isinstance(n.value, ast.Name)
                    and any(isinstance(t, ast.Name) and t.id == "ADAPTER" for t in n.targets))
        cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == name)
        declared = {t.id: ast.literal_eval(n.value) for n in cls.body if isinstance(n, ast.Assign)
                    for t in n.targets if isinstance(t, ast.Name) and t.id in ("VENDOR", "HOST_API", "VERSION")}
    except (StopIteration, SyntaxError, ValueError):
        raise AdapterRejected("the release declares no ADAPTER class with literal constants") from None
    if declared.get("VENDOR") != vendor:
        raise AdapterRejected(f"adapter is for {declared.get('VENDOR')!r}, not {vendor!r}")
    if declared.get("HOST_API") not in SUPPORTED_HOST_APIS:
        raise AdapterRejected(f"adapter needs host API {declared.get('HOST_API')}, this host has {sorted(SUPPORTED_HOST_APIS)}")
    if not isinstance(declared.get("VERSION"), int) or declared["VERSION"] < min_version:
        raise AdapterRejected(f"release v{declared.get('VERSION')} is older than the bundled v{min_version}")


def _bundled(vendor):
    """The adapter built into this package, if it is this vendor's (build.py --vendor)."""
    if vendor not in VENDOR_MODULES:
        return None
    name = f"adapters.{VENDOR_MODULES[vendor]}"
    try:
        module = importlib.import_module(name)
    except ModuleNotFoundError as e:
        if e.name != name:
            raise
        return None
    return _checked(getattr(module, "ADAPTER", None), vendor)


def _verify(source, signature):
    # Imported here: a package missing its native backend (DEV-24131) still runs the
    # built-in adapter, and reports why.
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    for key in PUBLIC_KEYS:
        try:
            Ed25519PublicKey.from_public_bytes(base64.b64decode(key)).verify(signature, source)
            return
        except InvalidSignature:
            continue
    raise AdapterRejected("signature does not verify against any trusted key")


def _checked(adapter, vendor):
    if adapter is None:
        raise AdapterRejected("the module defines no ADAPTER")
    if getattr(adapter, "VENDOR", None) != vendor:
        raise AdapterRejected(f"adapter is for {getattr(adapter, 'VENDOR', None)!r}, not {vendor!r}")
    if getattr(adapter, "HOST_API", None) not in SUPPORTED_HOST_APIS:
        raise AdapterRejected(f"adapter needs host API {getattr(adapter, 'HOST_API', None)}, this host has {sorted(SUPPORTED_HOST_APIS)}")
    if not isinstance(getattr(adapter, "ROOT_KEY", None), str) or not isinstance(getattr(adapter, "VERSION", None), int):
        raise AdapterRejected("adapter must define ROOT_KEY (str) and VERSION (int)")
    if not callable(getattr(adapter, "collect", None)):
        raise AdapterRejected("adapter must define collect(target, sdk)")
    return adapter
