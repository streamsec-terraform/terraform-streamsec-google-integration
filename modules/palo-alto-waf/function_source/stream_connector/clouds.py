"""The cloud-specific half of the Sdk: where secrets live and how a private IP maps to an
instance. Each host package ships one of these; adapters never import it.

Ported from the per-cloud utils.py of lambda_functions/waf, azure/functions/waf-azure and
gcp/functions/waf-gcp (same lookups, same secret shapes).
"""

import json
import logging
import os
import re

log = logging.getLogger("stream_connector")


def _json_or_text(value):
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return value


class AwsCloud:
    def get_secret(self, ref, name=None):
        import boto3

        log.info("Retrieving secret '%s' from AWS Secrets Manager...", ref)
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=ref).get("SecretString")
        if not secret:
            raise ValueError("SecretString not found in response")
        return _json_or_text(secret)

    def instance_id_for_ip(self, ip):
        import boto3

        try:
            response = boto3.client("ec2").describe_network_interfaces(
                Filters=[{"Name": "addresses.private-ip-address", "Values": [ip]}]
            )
            for nic in response.get("NetworkInterfaces", []):
                instance_id = (nic.get("Attachment") or {}).get("InstanceId")
                if instance_id:
                    return instance_id
        except Exception as e:
            log.warning("Could not resolve the EC2 instance for IP %s: %s", ip, e)
        return None

    def stream_token(self):
        return self.get_secret(os.environ["API_SECRET_NAME"])


class AzureCloud:
    def get_secret(self, ref, name=None):
        """`ref` is the Key Vault's resource ID and `name` the secret's name in it."""
        from azure.identity import DefaultAzureCredential
        from azure.keyvault.secrets import SecretClient

        vault_uri = f"https://{ref.split('/vaults/')[1]}.vault.azure.net"
        log.info("Retrieving secret '%s' from Azure Key Vault...", name)
        # JSON parsed as on AWS and GCP: an F5 {"username", "password"} secret is a dict
        return _json_or_text(SecretClient(vault_url=vault_uri, credential=DefaultAzureCredential()).get_secret(name).value or "")

    def instance_id_for_ip(self, ip):
        return None

    def stream_token(self):
        return os.environ["API_TOKEN"]


class GcpCloud:
    _SECRET_REF = re.compile(r"(projects/[^/]+/secrets/[^/]+)(?:/versions/([^/]+))?")

    def __init__(self):
        self._client = None

    def get_secret(self, ref, name=None):
        """`ref` is a Secret Manager secret or secret version: projects/<p>/secrets/<s>[/versions/<v>]."""
        from google.cloud import secretmanager

        match = self._SECRET_REF.fullmatch((ref or "").strip().strip("/"))
        if not match:
            raise ValueError(f"api_key must be a Secret Manager resource name (projects/<p>/secrets/<s>[/versions/<v>]), got {ref!r}")
        version = f"{match.group(1)}/versions/{match.group(2) or 'latest'}"
        if self._client is None:
            self._client = secretmanager.SecretManagerServiceClient()
        log.info("Retrieving secret '%s' from Secret Manager...", version)
        response = self._client.access_secret_version(request={"name": version})
        return _json_or_text(response.payload.data.decode("utf-8"))

    def instance_id_for_ip(self, ip):
        return None

    def stream_token(self):
        return os.environ["API_TOKEN"]
