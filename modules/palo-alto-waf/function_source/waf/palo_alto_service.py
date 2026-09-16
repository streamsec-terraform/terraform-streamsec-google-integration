import logging
import ssl
import traceback
import urllib.request
import uuid
import xml.etree.ElementTree as ET

from .utils import get_secret_value, report_error_to_backend

SUCCESS_STATUS = "success"


def palo_alto_process_fw_list(fw_list):
    logging.info(f"Processing firewall list: {fw_list}")
    fw_array = []
    for fw in fw_list:
        try:
            firewall_service = PaloAltoService(fw)
            device_id, version = firewall_service.get_general_info()
            network_interfaces = firewall_service.get_network_interfaces()
            routes = firewall_service.get_routes()
            nat_rules = firewall_service.get_nat_rules()
            addresses = firewall_service.get_addresses()
            security_policies = firewall_service.get_security_policies()
            zones = firewall_service.get_zones()
            instance_id = fw.get("resource_id", fw.get("url"))

            fw_array.append(
                {
                    "ngfw_name": f"{instance_id}_ngfw",
                    "instance_id": instance_id,
                    "version": version,
                    "device_id": device_id,
                    "interfaces": network_interfaces,
                    "routes": routes,
                    "nat_rules": nat_rules,
                    "address_objects": addresses,
                    "security_policies": security_policies,
                    "zones": zones,
                }
            )
        except Exception:
            logging.error(
                f"Error fetching details for firewall {fw.get('resource_id', fw.get('url'))}: {traceback.format_exc()}"
            )
            error_message = str(traceback.format_exc())
            report_error_to_backend(error_message)
    return fw_array


class PaloAltoService:
    def __init__(self, firewall_config):
        """
        Initialize PaloAltoService with firewall config containing API key secret ARN.
        """
        self.base_url = f"https://{firewall_config['url']}/api"
        self.resource_id = firewall_config.get("resource_id", self.base_url)
        self.secret_name = firewall_config.get("secret_name", "")
        self.api_key_field = firewall_config.get("api_key", "")

        if self.api_key_field:
            self.api_key = get_secret_value(self.api_key_field, self.secret_name)
        else:
            self.api_key = firewall_config.get("token", "")

        self.ssl_context = ssl._create_unverified_context()  # Ignore SSL cert verification
        logging.info(f"Palo Alto Service initialized (api key {'set' if self.api_key else 'missing'})")

    def make_request(self, endpoint, target_device=None):
        """
        Send a request to the Palo Alto API using urllib.request (built-in).
        """
        url = f"{self.base_url}/{endpoint}"
        headers = {"X-PAN-KEY": self.api_key}
        if target_device:
            headers["X-PAN-DEVICE-NAME"] = target_device

        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, context=self.ssl_context) as response:
                if response.getcode() == 200:
                    body = response.read().decode("utf-8")
                    result = self.parse_xml_response(body)
                    if not isinstance(result, dict):
                        raise Exception(f"Unexpected XML response format: {body[:200]}")
                    status = result.get("@attributes", {}).get("status", "")
                    if status == SUCCESS_STATUS:
                        return result.get("result", {}) or {}
                    else:
                        logging.error(f"API call failed with status {status}, {result}")
                        raise Exception("API call failed")
                else:
                    logging.error(f"Error: API call failed with status {response.getcode()}")
        except Exception as e:
            logging.error(f"Unexpected error during API request: {str(e)}")
            raise

        return {}

    def parse_xml_response(self, xml_data):
        """Parses XML response from Palo Alto API into a dictionary."""
        try:
            root = ET.fromstring(xml_data)
            return self.xml_to_dict(root)
        except ET.ParseError as e:
            logging.error(f"XML Parsing error: {str(e)}")
            return {}

    def xml_to_dict(self, elem):
        """Recursively converts an XML element to a dictionary."""
        children = list(elem)
        if not children:
            # Leaf element – return just the text value.
            # @attributes on leaf elements contain only Palo Alto edit metadata
            # (admin, dirtyId, time) which cause false diffs downstream.
            return elem.text.strip() if elem.text else None

        result = {}
        if elem.attrib:
            result["@attributes"] = elem.attrib

        child_dict = {}
        for child in children:
            converted = self.xml_to_dict(child)
            if child.tag in child_dict:
                if not isinstance(child_dict[child.tag], list):
                    child_dict[child.tag] = [child_dict[child.tag]]
                child_dict[child.tag].append(converted)
            else:
                child_dict[child.tag] = converted

        result.update(child_dict)
        return result

    def get_general_info(self):
        response = self.make_request("?type=op&cmd=<show><system><info></info></system></show>")
        general_info_dict = response.get("system", {})
        device_id = general_info_dict.get("vm-uuid", "")
        version = general_info_dict.get("sw-version", "")
        return device_id, version

    def get_managed_devices(self):
        response = self.make_request("?type=op&cmd=<target><show>all</show></target>")
        devices = []
        entries = response.get("devices", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            devices.append(
                {
                    "hostname": entry.get("hostname", ""),
                    "serial": entry.get("serial", ""),
                    "ip": entry.get("ip-address", ""),
                    "connected": entry.get("connected", "") == "yes",
                    "model": entry.get("model", ""),
                    "swVersion": entry.get("sw-version", ""),
                }
            )

        return devices

    def get_network_interfaces(self, target_device=None):
        response = self.make_request("?type=op&cmd=<show><interface>all</interface></show>", target_device)
        logging.info(f"get network interface Response: {response}")
        interfaces = []
        hw_entries = response.get("hw", {}).get("entry", [])
        ifnet_entries = response.get("ifnet", {}).get("entry", [])

        if isinstance(hw_entries, dict):
            hw_entries = [hw_entries]
        if isinstance(ifnet_entries, dict):
            ifnet_entries = [ifnet_entries]

        ifnet_map = {entry.get("name"): entry for entry in ifnet_entries}

        for hw_entry in hw_entries:
            name = hw_entry.get("name", "")
            ifnet_entry = ifnet_map.get(name, {})

            addr_field = ifnet_entry.get("addr") or {}
            secondary_ips = []
            if isinstance(addr_field, dict):
                member = addr_field.get("member", [])
                secondary_ips = [member] if isinstance(member, str) else member

            interfaces.append(
                {
                    "name": name,
                    "id": hw_entry.get("id", ""),
                    "type": hw_entry.get("type", ""),
                    "mac": hw_entry.get("mac", ""),
                    "speed": hw_entry.get("speed", ""),
                    "duplex": hw_entry.get("duplex", ""),
                    "state": hw_entry.get("state", ""),
                    "mode": hw_entry.get("mode", ""),
                    "fec": hw_entry.get("fec", ""),
                    "st": hw_entry.get("st", ""),
                    "tag": ifnet_entry.get("tag", ""),
                    "vsys": ifnet_entry.get("vsys", ""),
                    "zone": ifnet_entry.get("zone", ""),
                    "fwd": f"vr:{ifnet_entry.get('fwd', '').split(':')[-1]}",
                    "main_ip": ifnet_entry.get("ip", ""),
                    "secondary_ips": secondary_ips,
                    "dynAddr": "",
                    "addr6": "",
                }
            )

        return interfaces

    def get_routes(self, target_device=None):
        response = self.make_request("?type=op&cmd=<show><routing><route></route></routing></show>", target_device)
        logging.info(f"get routing table Response: {response}")

        routes = []
        entries = response.get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            next_hop = entry.get("nexthop", "0.0.0.0")
            flags = f"{entry.get('flags', '').strip()}   "
            routes.append(
                {
                    "virtualRouter": entry.get("virtual-router", ""),
                    "destination": entry.get("destination", ""),
                    "nextHop": next_hop,
                    "metric": int(entry.get("metric", "0")),
                    "flags": flags,
                    "age": "",
                    "interface": entry.get("interface", ""),
                    "routeTable": entry.get("route-table", ""),
                }
            )

        return routes

    def get_nat_rules(self, target_device=None):
        response = self.make_request(
            "?type=config&action=get&xpath=/config/devices/entry/vsys/entry/rulebase/nat/rules", target_device
        )
        logging.info(f"get NAT rules Response: {response}")

        rules = []
        results = response
        entries = results.get("rules", {}).get("entry", []) if results else []

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            name = entry.get("@attributes", {}).get("name", "")
            uuid_value = entry.get("@attributes", {}).get("uuid", "")

            if not name:
                continue

            translated_address = entry.get("destination-translation", {}).get("translated-address", "")
            rules.append(
                {
                    "name": name,
                    "uuid": uuid_value,
                    "from": self._get_members(entry.get("from", {})),
                    "to": self._get_members(entry.get("to", {})),
                    "source": self._get_members(entry.get("source", {})),
                    "destination": self._get_members(entry.get("destination", {})),
                    "service": self._get_members(entry.get("service", {})),
                    "destination_translation": {
                        "translated_address": list(
                            map(lambda x: x["value"] if isinstance(x, dict) and "value" in x else x, translated_address)
                        )
                        if isinstance(translated_address, list)
                        else translated_address
                    },
                }
            )

        return rules

    def get_addresses(self, target_device=None):
        response = self.make_request(
            "?type=config&action=get&xpath=/config/devices/entry/vsys/entry/address", target_device
        )
        logging.info(f"get address objects Response: {response}")

        addresses = []
        entries = response.get("address", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            name = entry.get("@attributes", {}).get("name", "")
            description = entry.get("@attributes", {}).get("description", "")

            if not name:
                continue

            addr_obj = {"name": name, "description": description}
            if entry.get("ip-netmask"):
                addr_obj["ip_netmask"] = entry.get("ip-netmask")
            elif entry.get("fqdn"):
                addr_obj["fqdn"] = entry.get("fqdn")

            addresses.append(addr_obj)

        return addresses

    def get_security_policies(self, target_device=None):
        response = self.make_request(
            "?type=config&action=get&xpath=/config/devices/entry/vsys/entry/rulebase/security/rules", target_device
        )
        logging.info(f"get security policies Response: {response}")

        rules = []
        entries = response.get("rules", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            name = entry.get("@attributes", {}).get("name", "")
            if not name:
                continue

            rules.append(
                {
                    "name": name,
                    "uuid": str(uuid.uuid4()),
                    "from": self._get_members(entry.get("from", {})),
                    "to": self._get_members(entry.get("to", {})),
                    "source": self._get_members(entry.get("source", {})),
                    "destination": self._get_members(entry.get("destination", {})),
                    "application": self._get_members(entry.get("application", {})),
                    "service": self._get_members(entry.get("service", {})),
                    "action": entry.get("action", ""),
                    "source_user": ["any"],
                    "category": ["any"],
                    "source_hip": ["any"],
                    "destination_hip": ["any"],
                    "description": entry.get("description", ""),
                }
            )

        return rules

    def get_zones(self, target_device=None):
        response = self.make_request(
            "?type=config&action=get&xpath=/config/devices/entry/vsys/entry/zone", target_device
        )
        logging.info(f"get zones Response: {response}")

        zones = []
        entries = response.get("zone", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            name = entry.get("@attributes", {}).get("name", "")
            if not name:
                continue

            zones.append(
                {"name": name, "network": {"layer3": self._get_members(entry.get("network", {}).get("layer3", {}))}}
            )

        return zones

    def _get_members(self, obj):
        """Members of a PAN-OS list field (service / source / destination / from / to).

        The XML API renders a multi-valued field as <member> elements and a single value as
        plain text (<service>tcp-80</service>), which xml_to_dict returns as a str; older
        parsers also yield {"value": ...}. Every shape must keep its value - returning "any"
        for a plain string reported every single-service NAT rule as open on all ports.
        An absent / empty field is "any" (PAN-OS semantics)."""
        if obj is None or obj == "" or obj == [] or obj == {}:
            return ["any"]
        if isinstance(obj, str):
            return [obj]
        if isinstance(obj, list):
            members = obj
        elif isinstance(obj, dict):
            if "member" in obj:
                members = obj["member"] if isinstance(obj["member"], list) else [obj["member"]]
            elif "value" in obj:
                members = [obj["value"]]
            else:
                return ["any"]
        else:
            return ["any"]
        return [m["value"] if isinstance(m, dict) and "value" in m else m for m in members]
