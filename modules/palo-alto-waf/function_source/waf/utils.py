import json
import logging
import os
import re
import traceback

import urllib3
from google.cloud import secretmanager

http = urllib3.PoolManager()


SUCCESS = "SUCCESS"
FAILED = "FAILED"


def make_api_call(method, url, body=None, headers=None):
    logging.info(f"Making API call to: {url}")
    return http.request(method, url, body=body, headers=headers)


def report_error_to_backend(error_message):
    """
    Report an error message to the backend API.

    :param api_token: API token for authentication.
    :param api_url: URL of the backend API.
    :param error_message: Error message to be reported.
    """
    api_url = get_value_from_env_var("API_URL")
    api_token = get_value_from_env_var("API_TOKEN")

    full_api_url = f"{api_url}/api/accounts/waf/error_report"
    headers = {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}
    body = json.dumps({"error_message": error_message})

    try:
        response = make_api_call("POST", full_api_url, body=body, headers=headers)
        if response.status == 200:
            logging.info("Error reported to backend successfully")
        else:
            logging.error(f"Failed to report error to backend: {response.data.decode('utf-8')}")
    except Exception as e:
        logging.error(f"Error reporting to backend: {str(e)}")


def get_value_from_env_var(env_var_name):
    logging.info(f"Retrieving value from environment variable '{env_var_name}'...")
    return os.environ.get(env_var_name)


_SECRET_REF_RE = re.compile(r"(projects/[^/]+/secrets/[^/]+)(?:/versions/([^/]+))?")
_secret_client = None


def _get_secret_client():
    """One Secret Manager client per warm instance (authenticates via ADC on first use)."""
    global _secret_client
    if _secret_client is None:
        _secret_client = secretmanager.SecretManagerServiceClient()
    return _secret_client


def _secret_version_name(secret_ref):
    """
    Normalize a Secret Manager reference to a full version resource name.
    Accepts a secret path (projects/<p>/secrets/<s>; /versions/latest is appended) or a
    version path (projects/<p>/secrets/<s>/versions/<v>). Anything else is rejected up
    front so a misconfigured api_key is reported as such rather than as a gRPC error.
    """
    match = _SECRET_REF_RE.fullmatch((secret_ref or "").strip().strip("/"))
    if not match:
        raise ValueError(
            "api_key must be a Secret Manager resource name "
            f"(projects/<p>/secrets/<s>[/versions/<v>]), got {secret_ref!r}"
        )
    return f"{match.group(1)}/versions/{match.group(2) or 'latest'}"


def get_secret_value(secret_ref, secret_name=None):
    """
    Retrieve the secret value from GCP Secret Manager.
    Same signature as the Azure implementation so the service modules stay identical;
    on GCP the reference itself addresses the secret, so `secret_name` is unused.
    :param secret_ref: Secret Manager secret or secret-version resource name
                       (projects/<p>/secrets/<s>[/versions/<v|latest>]).
    :param secret_name: Unused (Azure Key Vault shape). Kept for signature parity.
    :return: Secret value as a dictionary (if JSON) or a string. Returns None on error.
    """
    name = secret_ref
    try:
        name = _secret_version_name(secret_ref)
        logging.info(f"Retrieving secret '{name}' from Secret Manager...")

        # Authenticates with the function's runtime service account (ADC).
        response = _get_secret_client().access_secret_version(request={"name": name})
        secret_value = response.payload.data.decode("utf-8")
        logging.info(f"Retrieved secret '{name}' successfully.")

        try:
            return json.loads(secret_value)
        except (ValueError, TypeError):
            return secret_value

    except Exception as e:
        logging.error(f"Error retrieving secret '{name}': {str(e)}")
        error_message = traceback.format_exc()
        report_error_to_backend(error_message)
        return None
