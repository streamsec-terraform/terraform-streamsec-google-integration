import gzip
import json
import logging
import os
import traceback

from .fortinet_service import fortinet_process_fw_list
from .palo_alto_service import palo_alto_process_fw_list
from .utils import make_api_call, report_error_to_backend


def get_firewall_list(api_url, api_token):
    """
    Query the backend API to fetch the firewall list.

    :param api_token: API token for authentication.
    :param api_url: URL of the backend API.
    :return: List of firewalls (if successful) or an empty list if an error occurs.
    """

    full_api_url = f"{api_url}/api/accounts/waf/firewalls"

    headers = {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}

    try:
        response = make_api_call("GET", full_api_url, headers=headers)

        if response.status == 200:
            response_data = response.data.decode("utf-8")
            data = json.loads(response_data).get("data")
            return data if isinstance(data, dict) else {}

        logging.error(f"Error fetching firewall list: HTTP {response.status}")
        report_error_to_backend(f"firewalls endpoint returned HTTP {response.status}")

    except Exception as e:
        logging.error(f"Error fetching firewall list: {str(e)}")
        error_message = str(traceback.format_exc())
        report_error_to_backend(error_message)

    return {}


def collect_fw_list():
    """
    Retrieves the list of Palo Alto firewalls and prints their details.
    """

    api_url = os.getenv("API_URL")
    api_secret_value = os.getenv("API_TOKEN")
    if not api_url or not api_secret_value:
        raise RuntimeError("API_URL and API_TOKEN must be set (see README: --set-env-vars / --set-secrets)")

    fw_data = get_firewall_list(api_url, api_secret_value) or {}
    fw_list = fw_data.get("firewalls") or []
    fw_type = fw_data.get("type", "")
    logging.info(f"Retrieved {len(fw_list)} firewall(s) for type: {fw_type}")
    if fw_type == "palo-alto":
        logging.info("Processing Palo Alto firewall list")
        fw_array = palo_alto_process_fw_list(fw_list)
        send_fw_to_stream(api_url, api_secret_value, {"palo_alto_ngfw": fw_array})
    if fw_type == "fortinet":
        logging.info("Processing Fortinet firewall list")
        fw_array = fortinet_process_fw_list(fw_list)
        send_fw_to_stream(api_url, api_secret_value, {"fortinet_ngfw": fw_array})


GZIP_THRESHOLD_BYTES = 512 * 1024  # 512 KB


def send_fw_to_stream(api_url, api_token, fw_dict):
    full_url = f"{api_url}/api/v1/collection/waf-audit"
    logging.info(
        f"Sending firewall details to stream security: "
        f"{ {k: len(v) if isinstance(v, list) else 1 for k, v in fw_dict.items()} }"
    )
    headers = {"X-Lightlytics-Token": api_token, "Content-Type": "application/json"}
    body = json.dumps({"data": json.dumps(fw_dict)})

    if len(body) >= GZIP_THRESHOLD_BYTES:
        compressed_body = gzip.compress(body.encode("utf-8"))
        headers["Content-Encoding"] = "gzip"
        logging.info(
            f"Sending firewall details (gzip). Original: {len(body)} bytes ({len(body) / 1024:.1f} KB), "
            f"Compressed: {len(compressed_body)} bytes ({len(compressed_body) / 1024:.1f} KB)"
        )
        send_body = compressed_body
    else:
        logging.info(f"Sending firewall details (json). Payload size: {len(body)} bytes ({len(body) / 1024:.1f} KB)")
        send_body = body

    response = make_api_call("POST", full_url, body=send_body, headers=headers)

    if response.status == 200:
        logging.info("Firewall details sent to the stream successfully")
    else:
        logging.info(f"Error sending firewall details to the stream: {response.data.decode('utf-8')}")
