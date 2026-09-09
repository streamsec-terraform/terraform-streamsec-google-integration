"""Stream Security WAF/NGFW poller for GCP (Cloud Functions 2nd gen).

Same `waf` package as the Azure Function (azure/functions/waf-azure); only the
trigger (HTTP, invoked by Cloud Scheduler every 5 minutes) and the secret
backend (Secret Manager, see waf/utils.py) differ.

Runtime env:
  API_URL    Stream tenant base URL, e.g. https://app.streamsec.io
  API_TOKEN  Stream integration token (mounted from Secret Manager)
"""

import logging

# Cloud Functions gen2 leaves the root logger at WARNING (functions-framework only
# calls setup_logging() for the legacy ENTRY_POINT runtime), so every logging.info
# below and in waf/ would be dropped. Raise it first, as the Azure worker does.
logging.basicConfig(level=logging.INFO)

import functions_framework
from waf.waf_collector import collect_fw_list


@functions_framework.http
def poll(request):
    logging.info("Starting WAF poll")
    try:
        collect_fw_list()
    except Exception as e:
        logging.error(f"Error collecting firewall list: {str(e)}")
        raise
    logging.info("WAF poll finished")
    return "ok", 200
