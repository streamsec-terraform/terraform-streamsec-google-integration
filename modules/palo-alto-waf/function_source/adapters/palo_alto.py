"""Stream connector adapter: Palo Alto PAN-OS NGFW (XML API).

Port of lambda_functions/waf/code/palo_alto.py: the same calls and the same output. The
credential, HTTP and error reporting come from the Sdk the host passes in.
"""

import logging
import traceback
import xml.etree.ElementTree as ET

SUCCESS_STATUS = "success"


class PaloAltoAdapter:
    VENDOR = "palo-alto"
    ROOT_KEY = "palo_alto_ngfw"
    VERSION = 1
    HOST_API = 1

    def collect(self, target, sdk):
        firewall_service = PaloAltoService(target, sdk)
        device_id, version = firewall_service.get_general_info()
        network_interfaces = firewall_service.get_network_interfaces()
        routes = firewall_service.get_routes()
        nat_rules = firewall_service.get_nat_rules()
        addresses = firewall_service.get_addresses()
        address_groups = firewall_service.get_address_groups()
        services = firewall_service.get_services()
        service_groups = firewall_service.get_service_groups()
        security_policies = firewall_service.get_security_policies()
        intrazone_default_action, interzone_default_action = firewall_service.get_default_security_rules()
        zones = firewall_service.get_zones()
        instance_id = target.instance_id

        return {
            "ngfw_name": f"{instance_id}_ngfw",
            "ngfw_type": "palo-alto",
            "instance_id": instance_id,
            "version": version,
            "device_id": device_id,
            "interfaces": network_interfaces,
            "routes": routes,
            "nat_rules": nat_rules,
            "address_objects": addresses,
            "address_groups": address_groups,
            "services": services,
            "service_groups": service_groups,
            "security_policies": security_policies,
            "intrazone_default_action": intrazone_default_action,
            "interzone_default_action": interzone_default_action,
            "zones": zones
        }


class PaloAltoService:
    def __init__(self, target, sdk):
        self.http = sdk.http(f"https://{target.url}/api", headers={"X-PAN-KEY": sdk.credential()})
        logging.info("Palo Alto Service initialized")

    def make_request(self, endpoint, target_device=None):
        """
        Send a request to the Palo Alto API.
        """
        headers = {"X-PAN-DEVICE-NAME": target_device} if target_device else {}
        try:
            body = self.http.request("GET", f"/{endpoint}", headers=headers).decode("utf-8")
            result = self.parse_xml_response(body)
            if not isinstance(result, dict):
                raise Exception(f"Unexpected XML response format: {body[:200]}")
            status = result.get("@attributes", {}).get("status", "")
            if status == SUCCESS_STATUS:
                return result.get("result", {}) or {}
            else:
                logging.error(f"API call failed with status {status}, {result}")
                raise Exception("API call failed")
        except Exception as e:
            logging.error(f"Unexpected error during API request: {str(e)}")
            raise

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
        general_info_dict =response.get("system", {})
        device_id = general_info_dict.get("vm-uuid", "")
        version = general_info_dict.get("sw-version", "")
        return device_id, version

    def get_managed_devices(self):
        response = self.make_request("?type=op&cmd=<target><show>all</show></target>")
        devices = []
        entries =response.get("devices", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            devices.append({
                "hostname": entry.get("hostname", ""),
                "serial": entry.get("serial", ""),
                "ip": entry.get("ip-address", ""),
                "connected": entry.get("connected", "") == "yes",
                "model": entry.get("model", ""),
                "swVersion": entry.get("sw-version", ""),
            })

        return devices

    def get_network_interfaces(self, target_device=None):
        response = self.make_request("?type=op&cmd=<show><interface>all</interface></show>", target_device)
        logging.info(f"get network interface Response: {response}")
        interfaces = []
        hw_entries =response.get("hw", {}).get("entry", [])
        ifnet_entries =response.get("ifnet", {}).get("entry", [])

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

            interfaces.append({
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
            })

        return interfaces

    def get_routes(self, target_device=None):
        response = self.make_request("?type=op&cmd=<show><routing><route></route></routing></show>", target_device)
        logging.info(f"get routing table Response: {response}")

        routes = []
        entries =response.get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            next_hop = entry.get("nexthop", "0.0.0.0")
            flags = f"{entry.get('flags', '').strip()}   "
            routes.append({
                "virtualRouter": entry.get("virtual-router", ""),
                "destination": entry.get("destination", ""),
                "nextHop": next_hop,
                "metric": int(entry.get("metric", "0")),
                "flags": flags,
                "age": "",
                "interface": entry.get("interface", ""),
                "routeTable": entry.get("route-table", "")
            })

        return routes

    def get_nat_rules(self, target_device=None):
        response = self.make_request(
            "?type=config&action=get&xpath=/config/devices/entry/vsys/entry/rulebase/nat/rules", target_device
        )
        logging.info(f"get NAT rules Response: {response}")

        rules = []
        results =response
        entries = results.get("rules", {}).get("entry", []) if results else []

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            name = entry.get("@attributes", {}).get("name", "")
            uuid_value = entry.get("@attributes", {}).get("uuid", "")

            if not name:
                continue

            translated_address = entry.get("destination-translation", {}).get("translated-address", "")
            rules.append({
                "name": name,
                "uuid": uuid_value,
                "from": self._get_members(entry.get("from", {})),
                "to": self._get_members(entry.get("to", {})),
                "source": self._get_members(entry.get("source", {})),
                "destination": self._get_members(entry.get("destination", {})),
                "service": self._get_members(entry.get("service", {})),
                "destination_translation": {
                    "translated_address": list(map(lambda x: x["value"] if isinstance(x, dict) and "value" in x else x, translated_address)) if isinstance(translated_address, list) else translated_address
                }
            })

        return rules

    def get_addresses(self, target_device=None):
        addresses = []
        for scope, entry in self._get_object_entries("address", target_device):
            addr_obj = {
                "name": entry["@attributes"]["name"],
                "description": self._get_text(entry.get("description")),
                "scope": scope,
                # dynamic address groups select address objects by these tags
                "tags": self._get_member_list(entry.get("tag")),
            }
            for addr_type in ("ip-netmask", "ip-range", "ip-wildcard", "fqdn"):
                value = self._get_text(entry.get(addr_type))
                if value:
                    addr_obj["type"] = addr_type
                    addr_obj[addr_type.replace("-", "_")] = value
                    break

            addresses.append(addr_obj)

        return addresses

    def get_address_groups(self, target_device=None):
        groups = []
        for scope, entry in self._get_object_entries("address-group", target_device):
            dynamic = entry.get("dynamic")
            groups.append({
                "name": entry["@attributes"]["name"],
                "scope": scope,
                "type": "dynamic" if dynamic is not None else "static",
                # members may name other groups; resolution is by name against address_objects / address_groups
                "members": self._get_member_list(entry.get("static")),
                # the tag expression exactly as configured, e.g. 'web' and 'prod'
                "filter": self._get_text(dynamic.get("filter")) if isinstance(dynamic, dict) else "",
                "description": self._get_text(entry.get("description")),
            })

        return groups

    def get_services(self, target_device=None):
        services = []
        for scope, entry in self._get_object_entries("service", target_device):
            protocol_field = entry.get("protocol")
            protocol, port = "", ""
            if isinstance(protocol_field, dict):
                for name in ("tcp", "udp", "sctp"):
                    if name in protocol_field:
                        protocol = name
                        details = protocol_field.get(name)
                        port = self._get_text(details.get("port")) if isinstance(details, dict) else ""
                        break

            services.append({
                "name": entry["@attributes"]["name"],
                "scope": scope,
                "protocol": protocol,
                # destination ports as configured: "443", "8080-8090", "80,443,8000-8010"
                "port": port,
                "ports": [p.strip() for p in port.split(",") if p.strip()],
                "description": self._get_text(entry.get("description")),
            })

        return services

    def get_service_groups(self, target_device=None):
        groups = []
        for scope, entry in self._get_object_entries("service-group", target_device):
            groups.append({
                "name": entry["@attributes"]["name"],
                "scope": scope,
                # members may name other service groups or predefined services (service-http, service-https)
                "members": self._get_member_list(entry.get("members")),
            })

        return groups

    def get_security_policies(self, target_device=None):
        response = self.make_request("?type=config&action=get&xpath=/config/devices/entry/vsys/entry/rulebase/security/rules", target_device)
        logging.info(f"get security policies Response: {response}")

        rules = []
        entries =response.get("rules", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        # PAN-OS evaluates security rules top-down and the first match wins; the API returns
        # them in evaluation order, which downstream sorting loses unless it is carried here.
        for rule_index, entry in enumerate(entries):
            name = entry.get("@attributes", {}).get("name", "")
            if not name:
                continue

            rules.append({
                "name": name,
                "rule_index": rule_index,
                "uuid": entry.get("@attributes", {}).get("uuid", ""),
                "rule_type": self._get_text(entry.get("rule-type"), "universal"),
                "negate_source": self._get_text(entry.get("negate-source"), "no") == "yes",
                "negate_destination": self._get_text(entry.get("negate-destination"), "no") == "yes",
                "disabled": self._get_text(entry.get("disabled"), "no") == "yes",
                "from": self._get_members(entry.get("from", {})),
                "to": self._get_members(entry.get("to", {})),
                "source": self._get_members(entry.get("source", {})),
                "destination": self._get_members(entry.get("destination", {})),
                "application": self._get_members(entry.get("application", {})),
                "service": self._get_members(entry.get("service", {})),
                "action": entry.get("action", ""),
                "source_user": self._get_members(entry.get("source-user")),
                "category": self._get_members(entry.get("category")),
                "source_hip": self._get_members(entry.get("source-hip")),
                "destination_hip": self._get_members(entry.get("destination-hip")),
                # a rule with a schedule only matches inside its time window
                "schedule": self._get_text(entry.get("schedule")),
                "tags": self._get_member_list(entry.get("tag")),
                "group_tag": self._get_text(entry.get("group-tag")),
                "description": self._get_text(entry.get("description"))
            })

        return rules

    def get_default_security_rules(self, target_device=None):
        response = self._safe_request("?type=config&action=get&xpath=/config/devices/entry/vsys/entry/rulebase/default-security-rules/rules", target_device)
        logging.info(f"get default security rules Response: {response}")

        # Every zone pair ends with a default rule: intrazone allows, interzone denies. The
        # config node exists only when an admin overrides one of them.
        actions = {"intrazone-default": "allow", "interzone-default": "deny"}
        rules = response.get("rules") or {}
        entries = rules.get("entry", []) if isinstance(rules, dict) else []

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            if not isinstance(entry, dict):
                continue
            name = entry.get("@attributes", {}).get("name", "")
            action = self._get_text(entry.get("action"))
            if name in actions and action:
                actions[name] = action

        return actions["intrazone-default"], actions["interzone-default"]

    def get_zones(self, target_device=None):
        response = self.make_request("?type=config&action=get&xpath=/config/devices/entry/vsys/entry/zone", target_device)
        logging.info(f"get zones Response: {response}")

        zones = []
        entries =response.get("zone", {}).get("entry", [])

        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            name = entry.get("@attributes", {}).get("name", "")
            if not name:
                continue

            zones.append({
                "name": name,
                "network": {
                    "layer3": self._get_members(entry.get("network", {}).get("layer3", {}))
                }
            })

        return zones

    def _get_text(self, value, default=""):
        """A scalar PAN-OS field: plain text as xml_to_dict returns it; older parsers also yield {"value": ...}."""
        if isinstance(value, dict):
            value = value.get("value")
        return value if isinstance(value, str) and value else default

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
        values = [m["value"] if isinstance(m, dict) and "value" in m else m for m in members]
        # <member/> and {"member": []} decode to None / "" / [], which mean the field is
        # empty, not that a member is literally empty. Never emit those downstream.
        values = [v for v in values if v is not None and v != ""]
        return values or ["any"]

    def _safe_request(self, endpoint, target_device=None):
        """A request whose failure must not drop the whole firewall: log it and return no data."""
        try:
            return self.make_request(endpoint, target_device)
        except Exception:
            logging.error(f"Optional Palo Alto request failed, continuing without it: {endpoint}: {traceback.format_exc()}")
            return {}

    def _get_object_entries(self, kind, target_device=None):
        """(scope, entry) for every named object of a kind, vsys first, then shared.

        A vsys object shadows a shared one with the same name, as PAN-OS resolves references."""
        found = []
        seen = set()
        for scope, xpath in (("vsys", f"/config/devices/entry/vsys/entry/{kind}"), ("shared", f"/config/shared/{kind}")):
            response = self._safe_request(f"?type=config&action=get&xpath={xpath}", target_device)
            logging.info(f"get {scope} {kind} Response: {response}")
            containers = response.get(kind)
            # one container per matching vsys
            for container in containers if isinstance(containers, list) else [containers]:
                entries = container.get("entry", []) if isinstance(container, dict) else []
                if isinstance(entries, dict):
                    entries = [entries]
                for entry in entries:
                    if not isinstance(entry, dict):
                        continue
                    name = entry.get("@attributes", {}).get("name", "")
                    if not name or name in seen:
                        continue
                    seen.add(name)
                    found.append((scope, entry))
        return found

    def _get_member_list(self, obj):
        """<member> values of a list field; empty stays empty (an empty group matches nothing, unlike a rule field)."""
        if isinstance(obj, str):
            return [obj] if obj else []
        if not isinstance(obj, dict):
            return []
        members = obj.get("member", [])
        if not isinstance(members, list):
            members = [members]
        values = [m["value"] if isinstance(m, dict) and "value" in m else m for m in members]
        return [v for v in values if isinstance(v, str) and v]


ADAPTER = PaloAltoAdapter
