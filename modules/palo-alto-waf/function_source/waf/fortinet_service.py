import json
import logging
import ssl
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid

from .utils import get_secret_value, report_error_to_backend


def fortinet_process_fw_list(fw_list):
    """
    Processes the list of Fortinet firewalls and retrieves their configurations.

    :param fw_list: List of Fortinet firewall configurations.
    :return: List of processed firewall configurations.
    """
    logging.info(f"Processing Fortinet firewall list: {fw_list}")
    fw_array = []
    all_errors = {}
    for fw in fw_list:
        try:
            firewall_service = FortinetService(fw)
            fortinet_configurations = firewall_service.get_all()
            instance_id = fw.get("resource_id", fw.get("url"))

            fortinet_data = {
                "ngfw_name": f"{instance_id}_fortinet_ngfw",
                "ngfw_type": "fortinet",
                "instance_id": instance_id,
            }

            metadata = fortinet_configurations.pop("metadata", None)
            errors = metadata.get("errors", []) if metadata else []
            all_errors[instance_id] = errors

            fortinet_data.update(fortinet_configurations)
            fw_array.append(fortinet_data)

        except Exception as e:
            logging.error(f"Error processing firewall {fw.get('resource_id', fw.get('url'))}: {str(e)}")
            error_message = str(traceback.format_exc())
            report_error_to_backend(error_message)

    all_errors_str = "; ".join([f"{k}: {len(v)} errors" for k, v in all_errors.items() if v])
    if all_errors_str:
        logging.warning(f"Completed processing Fortinet firewalls with errors: {all_errors_str}")
        report_error_to_backend(all_errors_str)

    return fw_array


class FortinetService:
    def __init__(self, firewall_config):
        """
        Initialize FortinetService with firewall config.

        :param firewall_config: Dict containing firewall URL, resource_id,
                                and API key details (api_key_secret_name, api_key, or token)
        """
        self.url = firewall_config["url"]
        self.resource_id = firewall_config.get("resource_id", self.url)
        self.base_url = f"https://{self.url}/api/v2/cmdb"
        self.secret_name = firewall_config.get("secret_name", "")
        self.api_key_field = firewall_config.get("api_key", "")

        if self.api_key_field:
            self.api_key = get_secret_value(self.api_key_field, self.secret_name)
        else:
            self.api_key = firewall_config.get("token", "")

        if not self.api_key:
            raise ValueError("Fortinet API key or secret name not provided in configuration.")
        self.ssl_context = ssl._create_unverified_context()  # Ignore SSL cert verification
        logging.info("Fortinet Service initialized")

    def make_request(self, method, endpoint, params=None, payload=None):
        """
        Send a request to the Fortinet API using urllib.request and ssl.
        :param method: HTTP method (e.g., "GET", "POST")
        :param endpoint: API endpoint string (e.g., "firewall/policy")
        :param params: Optional dictionary of query parameters for GET requests
        :param payload: Optional dictionary for POST/PUT request body
        :return: Parsed JSON response as a dictionary
        """
        final_url = f"{self.base_url}/{endpoint}"
        headers = {"Authorization": f"Bearer {self.api_key}"}
        body_data = None

        if payload and method in ["POST", "PUT"]:
            headers["Content-Type"] = "application/json"
            body_data = json.dumps(payload).encode("utf-8")

        if params and method == "GET":
            query_string = urllib.parse.urlencode(params)
            final_url = f"{final_url}?{query_string}"

        try:
            print(f"Making API request: {method} {final_url}")

            # Create the request object
            request = urllib.request.Request(url=final_url, data=body_data, headers=headers, method=method)

            # Create SSL context (you can customize this based on your security requirements)
            # ssl_context = ssl.create_default_context()
            # If you need to disable SSL verification (not recommended for production):
            # ssl_context.check_hostname = False
            # ssl_context.verify_mode = ssl.CERT_NONE

            # Make the request
            with urllib.request.urlopen(request, context=self.ssl_context) as response:
                response_data_str = response.read().decode("utf-8")
                status_code = response.getcode()

                print(f"API response status: {status_code}, data snippet: {response_data_str[:250]}...")

                if status_code == 200:
                    result = json.loads(response_data_str)
                    return result
                else:
                    print(f"Error: API call failed with status {status_code}, response: {response_data_str}")
                    raise Exception(f"API call failed: {status_code} - {response_data_str}")

        except urllib.error.HTTPError as http_err:
            # Handle HTTP errors (4xx, 5xx status codes)
            error_response = http_err.read().decode("utf-8")
            print(f"HTTP Error: {http_err.code} - {error_response}")
            raise Exception(f"API call failed: {http_err.code} - {error_response}")

        except urllib.error.URLError as url_err:
            # Handle URL errors (network issues, DNS resolution, etc.)
            print(f"URL Error: {str(url_err)}")
            raise Exception(f"Network error: {str(url_err)}")

        except json.JSONDecodeError as je:
            print(f"JSON parsing error: {str(je)}. Response was: {response_data_str}")
            raise

        except Exception as e:
            print(f"Unexpected error during API request: {str(e)}")
            raise e

    def get_firewall_policies(self):
        """
        Retrieves firewall security policies from Fortinet NGFW.
        Fortinet VDOMs might require a 'vdom' parameter in params, e.g. {"vdom": "root"} or specific VDOM.
        Assuming global or default VDOM if not specified.
        """

        response_json = self.make_request("GET", "firewall/policy")

        policies = []

        raw_policies = response_json.get("results", [])

        if not isinstance(raw_policies, list):
            print(
                f"Warning: Expected a list of policies in 'results', got {type(raw_policies)}. Full response: {response_json}"
            )
            return policies

        for policy_data in raw_policies:
            policy_id = policy_data.get("policyid", "N/A")
            policy_uuid = policy_data.get("uuid", str(uuid.uuid4()))

            def get_member_names(items_list):
                if not items_list or not isinstance(items_list, list):
                    return ["any"]

                names = [item.get("name", "unknown_member") for item in items_list]
                return names if names else ["any"]

            policies.append(
                {
                    "name": policy_data.get("name", f"policy_{policy_id}"),
                    "uuid": policy_uuid,
                    "from": get_member_names(policy_data.get("srcintf")),
                    "to": get_member_names(policy_data.get("dstintf")),
                    "source": get_member_names(policy_data.get("srcaddr")),
                    "destination": get_member_names(policy_data.get("dstaddr")),
                    "application": get_member_names(policy_data.get("application")),
                    "service": get_member_names(policy_data.get("service")),
                    "action": policy_data.get("action", "unknown"),
                    "description": policy_data.get("comments", ""),
                    "status": policy_data.get("status", "enable"),
                    "source_user": ["any"],
                    "category": ["any"],
                }
            )
        return policies

    def get_all(self):
        """
        Retrieves all Fortinet configurations using the built-in async script.
        Error Handling: If any error occurs during the fetch, it will log the error and return an empty structure with error metadata.
        Returns:
            Dict containing all network and policy configurations with error metadata
        """
        try:
            # Import the function from our script
            from .fortinet_fetch import get_fortinet_config

            # Fetch all configurations using the script with this firewall's credentials
            config_data = get_fortinet_config(host=self.url, token=self.api_key)

            # Check for errors and warnings
            metadata = config_data.get("metadata", {})
            total_errors = metadata.get("total_errors", 0)
            total_warnings = metadata.get("total_warnings", 0)

            if total_errors > 0:
                logging.warning(f"Fortinet fetch completed with {total_errors} errors for {self.resource_id}")
                for error in metadata.get("errors", []):
                    logging.warning(f"  - {error.get('endpoint', 'unknown')}: {error.get('error', 'unknown error')}")
            elif total_warnings > 0:
                logging.info(f"Fortinet fetch completed with {total_warnings} warnings for {self.resource_id}")
            else:
                logging.info(f"Successfully fetched Fortinet configurations for {self.resource_id}")

            return config_data

        except Exception as e:
            logging.error(f"Error fetching Fortinet configurations for {self.resource_id}: {str(e)}")
            # Return empty structure on error with error metadata
            return {
                "network": {
                    "interfaces": [],
                    "static_routes": [],
                    "policy_routes": [],
                    "routing_objects": [],
                    "rip": [],
                    "ospf": [],
                    "bgp": [],
                    "multicast": [],
                },
                "policy": {
                    "firewall_policies": [],
                    "addresses": [],
                    "services": [],
                    "virtual_ips": [],
                    "ip_pools": [],
                    "protocol_options": [],
                },
                "users": {"admins": [], "local_users": [], "user_groups": [], "api_users": []},
                "metadata": {
                    "total_errors": 1,
                    "total_warnings": 0,
                    "errors": [{"endpoint": "fortinet_service", "error": str(e), "type": "service_exception"}],
                    "warnings": [],
                    "timestamp": 0,
                    "host": self.url,
                },
            }
