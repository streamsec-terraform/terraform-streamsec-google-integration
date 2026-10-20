"""One scheduled run: ask the backend which firewalls to collect, collect each with the
vendor's adapter, send the payload."""

import logging
import traceback

from stream_connector.loader import select_adapter
from stream_connector.sdk import Sdk, Target

log = logging.getLogger("stream_connector")


def run(api, cloud, updates_enabled=True):
    vendor, entries = api.get_firewalls()
    # Only url and resource_id: an entry can carry the inline token (the credential itself).
    log.info("Retrieved firewall list: %s, for type: %s",
             [{"url": e.get("url"), "resource_id": e.get("resource_id")} for e in entries], vendor)
    if not vendor:
        return

    adapter = select_adapter(vendor, api, updates_enabled)()
    log.info("Collecting %d %s firewalls with adapter v%s", len(entries), vendor, adapter.VERSION)
    elements = []
    for entry in entries:
        target = Target(url=entry.get("url", ""), resource_id=entry.get("resource_id"))
        try:
            element = adapter.collect(target, Sdk(cloud, api.report_error, entry))
        except Exception:
            log.error("Error collecting firewall %s: %s", target.instance_id, traceback.format_exc())
            api.report_error(traceback.format_exc())
            continue
        if element is not None:  # None: the adapter skipped this firewall (for example, unreachable)
            elements.append(element)
    api.send({adapter.ROOT_KEY: elements})
