"""
Fortinet Configuration Fetcher

Async script to fetch Fortinet configurations from APIs using only built-in Python libraries.
Uses urllib.request wrapped in asyncio for async HTTP requests.

Error Handling Strategy:
- Retry logic with exponential backoff (3 attempts: 2s, 4s, 6s delays)
- Partial results: Always return data even if some API calls fail
- Detailed error tracking with metadata for debugging
- Graceful degradation: Continue processing other endpoints on failures
"""

import asyncio
import json
import logging
import os
import ssl
import time
import urllib.error
import urllib.request
import warnings
from typing import Any, Dict, List, Optional

# Suppress SSL warnings for self-signed certificates
warnings.filterwarnings("ignore", message="Unverified HTTPS request")

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

# Configuration constants
MAX_RETRIES = 3
REQUEST_TIMEOUT = 15
RETRY_DELAY_BASE = 2

# Sensitive fields to strip from user/admin API responses before sending data.
# Keyed by the user_calls tuple key used in fetch_user_configurations().
SENSITIVE_FIELDS = {
    "admins": ["password", "passwd", "ssh-public-key1", "ssh-public-key2", "ssh-public-key3"],
    "local_users": ["passwd", "ppk-secret"],
    "user_groups": [],  # guest[].password handled separately in strip_sensitive_fields()
    "api_users": ["api-key"],
}

# Note: Host and token must be provided via environment variables or function parameters
# No hardcoded values - all configuration comes from external sources

# Create SSL context that ignores certificate verification
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE


async def safe_api_call(
    endpoint: str, base_url: str, token: str, params: Optional[Dict] = None, max_retries: int = MAX_RETRIES
) -> Dict[str, Any]:
    """
    Safely call Fortinet API endpoints with retry logic and detailed error handling.

    Error Handling Features:
    - Retry with exponential backoff (2s, 4s, 6s delays)
    - Detailed error categorization (HTTP, URL, JSON, general)
    - Graceful failure: Returns error metadata instead of crashing
    - Timeout protection (15 seconds per request)

    Args:
        endpoint: The API endpoint to call (e.g., '/cmdb/system/interface')
        base_url: The base URL for the Fortinet API
        token: The authentication token
        params: Optional query parameters
        max_retries: Maximum number of retry attempts (default: 3)

    Returns:
        Dict with structure:
        {
            "success": bool,
            "data": List[Dict] or [],
            "error": str or None,
            "endpoint": str,
            "attempts": int
        }
    """
    url = f"{base_url}{endpoint}"

    # Add query parameters if provided
    if params:
        query_string = "&".join([f"{k}={v}" for k, v in params.items()])
        url = f"{url}?{query_string}"

    # Create request with headers
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")

    logger.info(f"Calling API endpoint: {endpoint}")

    # Retry logic with exponential backoff
    for attempt in range(max_retries):
        try:
            # Use asyncio.to_thread to make the synchronous urllib.request async
            def make_request():
                try:
                    with urllib.request.urlopen(req, context=ssl_context, timeout=REQUEST_TIMEOUT) as response:
                        data = json.loads(response.read().decode("utf-8"))
                        return data
                except urllib.error.HTTPError as e:
                    error_msg = f"HTTP error for {endpoint}: {e.code} - {e.read().decode('utf-8')}"
                    logger.error(error_msg)
                    return {"error": error_msg, "code": e.code}
                except urllib.error.URLError as e:
                    error_msg = f"URL error for {endpoint}: {e.reason}"
                    logger.error(error_msg)
                    return {"error": error_msg, "reason": str(e.reason)}
                except json.JSONDecodeError as e:
                    error_msg = f"JSON decode error for {endpoint}: {str(e)}"
                    logger.error(error_msg)
                    return {"error": error_msg, "type": "json_decode"}
                except Exception as e:
                    error_msg = f"Request error for {endpoint}: {str(e)}"
                    logger.error(error_msg)
                    return {"error": error_msg, "type": "general"}

            # Run the synchronous request in a thread pool
            data = await asyncio.to_thread(make_request)

            # Check if we got an error response
            if isinstance(data, dict) and "error" in data:
                if attempt < max_retries - 1:
                    wait_time = (attempt + 1) * RETRY_DELAY_BASE
                    logger.warning(f"Attempt {attempt + 1} failed for {endpoint}, retrying in {wait_time}s...")
                    await asyncio.sleep(wait_time)
                    continue
                else:
                    return {
                        "success": False,
                        "data": [],
                        "error": data["error"],
                        "endpoint": endpoint,
                        "attempts": attempt + 1,
                    }

            # Handle successful response
            if isinstance(data, dict):
                if "results" in data:
                    return {"success": True, "data": data["results"], "error": None}
                elif "data" in data:
                    return {"success": True, "data": data["data"], "error": None}
                else:
                    return {"success": True, "data": [data], "error": None}
            elif isinstance(data, list):
                return {"success": True, "data": data, "error": None}
            else:
                logger.warning(f"Unexpected response format for {endpoint}: {type(data)}")
                return {"success": True, "data": [data] if data else [], "error": None}

        except Exception as e:
            error_msg = f"Unexpected error for {endpoint}: {str(e)}"
            logger.error(error_msg)
            if attempt < max_retries - 1:
                wait_time = (attempt + 1) * RETRY_DELAY_BASE
                logger.warning(f"Attempt {attempt + 1} failed for {endpoint}, retrying in {wait_time}s...")
                await asyncio.sleep(wait_time)
                continue
            else:
                return {"success": False, "data": [], "error": error_msg, "endpoint": endpoint, "attempts": attempt + 1}

    # This should never be reached, but just in case
    return {
        "success": False,
        "data": [],
        "error": f"All {max_retries} attempts failed for {endpoint}",
        "endpoint": endpoint,
        "attempts": max_retries,
    }


async def fetch_network_configurations(base_url: str, token: str) -> Dict[str, Any]:
    """
    Fetch all network-related configurations from Fortinet concurrently.

    Error Handling:
    - Each endpoint is processed independently
    - Failed endpoints return empty arrays
    - All errors are collected and returned in metadata
    - Processing continues even if some endpoints fail

    Returns:
        Dict with structure:
        {
            "config": Dict[str, List] - Network configuration data,
            "errors": List[Dict] - Error details for failed endpoints,
            "warnings": List[str] - Warnings for empty responses
        }
    """
    network_config = {
        "interfaces": [],
        "static_routes": [],
        "policy_routes": [],
        "routing_objects": [],
        "rip": [],
        "ospf": [],
        "bgp": [],
        "multicast": [],
    }

    errors = []
    warnings = []

    # Define all network API calls
    network_calls = [
        ("interfaces", "/cmdb/system/interface"),
        ("static_routes", "/cmdb/router/static"),
        ("policy_routes", "/cmdb/router/policy"),
        ("rip", "/cmdb/router/rip"),
        ("ospf", "/cmdb/router/ospf"),
        ("bgp", "/cmdb/router/bgp"),
        ("multicast", "/cmdb/router/multicast"),
    ]

    # Execute all network calls concurrently
    logger.info("Fetching network configurations concurrently...")
    tasks = [safe_api_call(endpoint, base_url, token) for _, endpoint in network_calls]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Process results and collect errors/warnings
    for i, (key, _) in enumerate(network_calls):
        if isinstance(results[i], Exception):
            error_msg = f"Exception in {key}: {results[i]}"
            logger.error(error_msg)
            errors.append({"endpoint": key, "error": error_msg, "type": "exception"})
            network_config[key] = []
        else:
            result = results[i]
            if result["success"]:
                network_config[key] = result["data"]
                if result["data"]:
                    logger.info(f"Successfully fetched {len(result['data'])} {key}")
                else:
                    warnings.append(f"No data returned for {key}")
            else:
                error_msg = f"Failed to fetch {key}: {result['error']}"
                logger.error(error_msg)
                errors.append(
                    {
                        "endpoint": key,
                        "error": result["error"],
                        "attempts": result.get("attempts", 1),
                        "type": "api_failure",
                    }
                )
                network_config[key] = []

    # Handle routing objects (Address Groups, Service Groups, etc.)
    logger.info("Fetching routing objects...")
    routing_objects = []

    # Fetch address groups and service groups concurrently
    addr_groups_task = safe_api_call("/cmdb/firewall/addrgrp", base_url, token)
    service_groups_task = safe_api_call("/cmdb/firewall.service/group", base_url, token)

    addr_groups, service_groups = await asyncio.gather(addr_groups_task, service_groups_task, return_exceptions=True)

    # Process address groups
    if isinstance(addr_groups, Exception):
        error_msg = f"Exception in address groups: {addr_groups}"
        logger.error(error_msg)
        errors.append({"endpoint": "address_groups", "error": error_msg, "type": "exception"})
        addr_groups = {"success": False, "data": [], "error": error_msg}
    else:
        addr_groups = addr_groups or {"success": False, "data": [], "error": "No response"}

    if addr_groups["success"]:
        for group in addr_groups["data"]:
            group["object_type"] = "address_group"
            routing_objects.append(group)
    else:
        errors.append(
            {
                "endpoint": "address_groups",
                "error": addr_groups["error"],
                "attempts": addr_groups.get("attempts", 1),
                "type": "api_failure",
            }
        )

    # Process service groups
    if isinstance(service_groups, Exception):
        error_msg = f"Exception in service groups: {service_groups}"
        logger.error(error_msg)
        errors.append({"endpoint": "service_groups", "error": error_msg, "type": "exception"})
        service_groups = {"success": False, "data": [], "error": error_msg}
    else:
        service_groups = service_groups or {"success": False, "data": [], "error": "No response"}

    if service_groups["success"]:
        for group in service_groups["data"]:
            group["object_type"] = "service_group"
            routing_objects.append(group)
    else:
        errors.append(
            {
                "endpoint": "service_groups",
                "error": service_groups["error"],
                "attempts": service_groups.get("attempts", 1),
                "type": "api_failure",
            }
        )

    network_config["routing_objects"] = routing_objects

    return {"config": network_config, "errors": errors, "warnings": warnings}


async def fetch_policy_configurations(base_url: str, token: str) -> Dict[str, Any]:
    """
    Fetch all policy-related configurations from Fortinet concurrently.

    Error Handling:
    - Each endpoint is processed independently
    - Failed endpoints return empty arrays
    - All errors are collected and returned in metadata
    - Processing continues even if some endpoints fail

    Returns:
        Dict with structure:
        {
            "config": Dict[str, List] - Policy configuration data,
            "errors": List[Dict] - Error details for failed endpoints,
            "warnings": List[str] - Warnings for empty responses
        }
    """
    policy_config = {
        "firewall_policies": [],
        "addresses": [],
        "services": [],
        "virtual_ips": [],
        "ip_pools": [],
        "protocol_options": [],
    }

    errors = []
    warnings = []

    # Define all policy API calls
    policy_calls = [
        ("firewall_policies", "/cmdb/firewall/policy"),
        ("addresses", "/cmdb/firewall/address"),
        ("services", "/cmdb/firewall.service/custom"),
        ("virtual_ips", "/cmdb/firewall/vip"),
        ("ip_pools", "/cmdb/firewall/ippool"),
        ("protocol_options", "/cmdb/firewall/profile-protocol-options"),
    ]

    # Execute all policy calls concurrently
    logger.info("Fetching policy configurations concurrently...")
    tasks = [safe_api_call(endpoint, base_url, token) for _, endpoint in policy_calls]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Process results and collect errors/warnings
    for i, (key, _) in enumerate(policy_calls):
        if isinstance(results[i], Exception):
            error_msg = f"Exception in {key}: {results[i]}"
            logger.error(error_msg)
            errors.append({"endpoint": key, "error": error_msg, "type": "exception"})
            policy_config[key] = []
        else:
            result = results[i]
            if result["success"]:
                policy_config[key] = result["data"]
                if result["data"]:
                    logger.info(f"Successfully fetched {len(result['data'])} {key}")
                else:
                    warnings.append(f"No data returned for {key}")
            else:
                error_msg = f"Failed to fetch {key}: {result['error']}"
                logger.error(error_msg)
                errors.append(
                    {
                        "endpoint": key,
                        "error": result["error"],
                        "attempts": result.get("attempts", 1),
                        "type": "api_failure",
                    }
                )
                policy_config[key] = []

    return {"config": policy_config, "errors": errors, "warnings": warnings}


def strip_sensitive_fields(records: List[Dict], endpoint_key: str) -> List[Dict]:
    """
    Remove sensitive fields (passwords, secrets, API keys) from API response records.

    Args:
        records: List of dicts from the Fortinet API response
        endpoint_key: Key from SENSITIVE_FIELDS identifying which fields to strip

    Returns:
        The same list with sensitive fields removed
    """
    fields_to_strip = SENSITIVE_FIELDS.get(endpoint_key, [])
    stripped_count = 0

    for record in records:
        for field in fields_to_strip:
            if field in record:
                del record[field]
                stripped_count += 1

        # Strip passwords from nested guest sub-tables in user_groups
        if endpoint_key == "user_groups":
            for guest in record.get("guest", []):
                if isinstance(guest, dict) and "password" in guest:
                    del guest["password"]
                    stripped_count += 1

    if stripped_count > 0:
        logger.info(f"Stripped {stripped_count} sensitive field(s) from {endpoint_key}")

    return records


async def fetch_user_configurations(base_url: str, token: str) -> Dict[str, Any]:
    """
    Fetch all user/admin-related configurations from Fortinet concurrently.
    Sensitive fields (passwords, API keys, secrets) are stripped immediately after fetch.

    Error Handling:
    - Each endpoint is processed independently
    - Failed endpoints return empty arrays
    - All errors are collected and returned in metadata
    - Processing continues even if some endpoints fail

    Returns:
        Dict with structure:
        {
            "config": Dict[str, List] - User configuration data,
            "errors": List[Dict] - Error details for failed endpoints,
            "warnings": List[str] - Warnings for empty responses
        }
    """
    user_config = {
        "admins": [],
        "local_users": [],
        "user_groups": [],
        "api_users": [],
    }

    errors = []
    warnings = []

    # Define all user/admin API calls
    user_calls = [
        ("admins", "/cmdb/system/admin"),
        ("local_users", "/cmdb/user/local"),
        ("user_groups", "/cmdb/user/group"),
        ("api_users", "/cmdb/system/api-user"),
    ]

    # Execute all user calls concurrently
    logger.info("Fetching user configurations concurrently...")
    tasks = [safe_api_call(endpoint, base_url, token) for _, endpoint in user_calls]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Process results, strip sensitive fields, and collect errors/warnings
    for i, (key, _) in enumerate(user_calls):
        if isinstance(results[i], Exception):
            error_msg = f"Exception in {key}: {results[i]}"
            logger.error(error_msg)
            errors.append({"endpoint": key, "error": error_msg, "type": "exception"})
            user_config[key] = []
        else:
            result = results[i]
            if result["success"]:
                user_config[key] = strip_sensitive_fields(result["data"], key)
                if result["data"]:
                    logger.info(f"Successfully fetched {len(result['data'])} {key}")
                else:
                    warnings.append(f"No data returned for {key}")
            else:
                error_msg = f"Failed to fetch {key}: {result['error']}"
                logger.error(error_msg)
                errors.append(
                    {
                        "endpoint": key,
                        "error": result["error"],
                        "attempts": result.get("attempts", 1),
                        "type": "api_failure",
                    }
                )
                user_config[key] = []

    return {"config": user_config, "errors": errors, "warnings": warnings}


async def fetch_all_fortinet_configurations(base_url: str, token: str) -> Dict[str, Any]:
    """
    Fetch all Fortinet configurations concurrently and return the nested dictionary structure.

    Error Handling Strategy:
    - Network, policy, and user configurations are fetched concurrently
    - Each section can fail independently without affecting the others
    - All errors and warnings are aggregated in metadata
    - Partial results are always returned

    Returns:
        Dict with structure:
        {
            "network": Dict[str, List] - Network configuration data,
            "policy": Dict[str, List] - Policy configuration data,
            "users": Dict[str, List] - User/admin configuration data,
            "metadata": {
                "total_errors": int,
                "total_warnings": int,
                "errors": List[Dict] - Detailed error information,
                "warnings": List[str] - Warning messages,
                "timestamp": float,
                "host": str
            }
        }
    """
    logger.info("Starting Fortinet configuration fetch (built-in async)...")

    # Fetch network, policy, and user configurations concurrently
    network_task = fetch_network_configurations(base_url, token)
    policy_task = fetch_policy_configurations(base_url, token)
    user_task = fetch_user_configurations(base_url, token)

    network_result, policy_result, user_result = await asyncio.gather(
        network_task, policy_task, user_task, return_exceptions=True
    )

    # Handle exceptions at the top level
    if isinstance(network_result, Exception):
        logger.error(f"Exception in network config: {network_result}")
        network_result = {
            "config": {
                "interfaces": [],
                "static_routes": [],
                "policy_routes": [],
                "routing_objects": [],
                "rip": [],
                "ospf": [],
                "bgp": [],
                "multicast": [],
            },
            "errors": [{"endpoint": "network_config", "error": str(network_result), "type": "exception"}],
            "warnings": [],
        }

    if isinstance(policy_result, Exception):
        logger.error(f"Exception in policy config: {policy_result}")
        policy_result = {
            "config": {
                "firewall_policies": [],
                "addresses": [],
                "services": [],
                "virtual_ips": [],
                "ip_pools": [],
                "protocol_options": [],
            },
            "errors": [{"endpoint": "policy_config", "error": str(policy_result), "type": "exception"}],
            "warnings": [],
        }

    if isinstance(user_result, Exception):
        logger.error(f"Exception in user config: {user_result}")
        user_result = {
            "config": {"admins": [], "local_users": [], "user_groups": [], "api_users": []},
            "errors": [{"endpoint": "user_config", "error": str(user_result), "type": "exception"}],
            "warnings": [],
        }

    # Combine all errors and warnings
    all_errors = network_result.get("errors", []) + policy_result.get("errors", []) + user_result.get("errors", [])
    all_warnings = (
        network_result.get("warnings", []) + policy_result.get("warnings", []) + user_result.get("warnings", [])
    )

    # Create summary
    total_errors = len(all_errors)
    total_warnings = len(all_warnings)

    if total_errors > 0:
        logger.warning(f"Configuration fetch completed with {total_errors} errors and {total_warnings} warnings")
    elif total_warnings > 0:
        logger.info(f"Configuration fetch completed with {total_warnings} warnings")
    else:
        logger.info("Configuration fetch completed successfully")

    result = {
        "network": network_result["config"],
        "policy": policy_result["config"],
        "users": user_result["config"],
        "metadata": {
            "total_errors": total_errors,
            "total_warnings": total_warnings,
            "errors": all_errors,
            "warnings": all_warnings,
            "timestamp": time.monotonic(),
            "host": base_url.replace("https://", "").replace("/api/v2", ""),
        },
    }

    logger.info("Fortinet configuration fetch completed (built-in async)")
    return result


def get_fortinet_config(host: str = None, token: str = None) -> Dict[str, Any]:
    """
    Simple function to get Fortinet configuration.
    Use this when importing the module.

    Error Handling:
    - Validates required parameters
    - Exception handling at the top level
    - Always returns a valid data structure

    Args:
        host: Fortinet host (required if not in FORTINET_HOST env var)
        token: Fortinet token (required if not in FORTINET_TOKEN env var)

    Returns:
        Dictionary with network and policy configurations, plus error metadata

    Raises:
        ValueError: If host or token is not provided
    """
    # Get host and token from parameters or environment variables
    final_host = host or os.environ.get("FORTINET_HOST")
    final_token = token or os.environ.get("FORTINET_TOKEN")

    # Validate required parameters
    if not final_host:
        raise ValueError("Host must be provided either as parameter or FORTINET_HOST environment variable")
    if not final_token:
        raise ValueError("Token must be provided either as parameter or FORTINET_TOKEN environment variable")

    # Construct base URL
    base_url = f"https://{final_host}/api/v2"

    try:
        return asyncio.run(fetch_all_fortinet_configurations(base_url, final_token))
    except Exception as e:
        logger.error(f"Failed to fetch Fortinet configurations: {str(e)}")
        # Return empty structure with error metadata
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
                "errors": [{"endpoint": "configuration_fetch", "error": str(e), "type": "fetch_exception"}],
                "warnings": [],
                "timestamp": 0,
                "host": final_host,
            },
        }
