"""Stream Security WAF/NGFW poller for GCP (Cloud Functions 2nd gen), invoked over HTTP by
Cloud Scheduler.

Runtime env:
  API_URL    Stream tenant base URL, e.g. https://app.streamsec.io
  API_TOKEN  Stream integration token (mounted from Secret Manager)
"""

import logging
import os

# Cloud Functions gen2 leaves the root logger at WARNING (functions-framework only
# calls setup_logging() for the legacy ENTRY_POINT runtime), so every logging.info
# would be dropped. Raise it first, as the Azure worker does.
logging.basicConfig(level=logging.INFO)

import functions_framework  # noqa: E402
from stream_connector.clouds import GcpCloud  # noqa: E402
from stream_connector.runner import run  # noqa: E402
from stream_connector.stream_api import StreamApi  # noqa: E402


@functions_framework.http
def poll(request):
    logging.info("Starting WAF poll")
    cloud = GcpCloud()
    run(StreamApi(os.environ["API_URL"], cloud.stream_token()), cloud,
        updates_enabled=os.environ.get("ADAPTER_UPDATES", "on") != "off")
    logging.info("WAF poll finished")
    return "ok", 200
