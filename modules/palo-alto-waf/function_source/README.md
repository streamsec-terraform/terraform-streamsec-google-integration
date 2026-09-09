# waf-gcp — Stream WAF/NGFW poller for GCP

Cloud Functions (2nd gen) port of `azure/functions/waf-azure`. Polls Palo Alto / Fortinet
firewalls reachable from the customer's VPC and posts their config to Stream.

## Layout

| Path | Role |
|---|---|
| `main.py` | HTTP entrypoint `poll` → `waf.waf_collector.collect_fw_list()` |
| `waf/` | `azure/functions/waf-azure/waf/`, ruff-formatted. Differs in `utils.get_secret_value` (Secret Manager instead of Key Vault), `waf_collector.send_fw_to_stream` (gzip branch from the AWS Lambda), and the service modules no longer log the firewall API key |
| `requirements.txt` | `functions-framework`, `google-cloud-secret-manager`, `urllib3` (pinned) |

## Runtime contract

| Env var | Value |
|---|---|
| `API_URL` | Stream tenant base URL, e.g. `https://app.streamsec.io` |
| `API_TOKEN` | Stream integration token. Mount from Secret Manager (`--set-secrets`), not plaintext |

Firewall list comes from `GET {API_URL}/api/accounts/waf/firewalls`. Each firewall's `api_key`
field is a Secret Manager resource name — `projects/<p>/secrets/<s>` or
`projects/<p>/secrets/<s>/versions/<v>` (`/versions/latest` appended when missing). The
function's service account needs `roles/secretmanager.secretAccessor` on every such secret.

Payloads >= 512 KB are gzip-compressed (`Content-Encoding: gzip`), same as the AWS Lambda.

## Deploy (Terraform)

Use `modules/palo-alto-waf` in `streamsec-terraform/terraform-streamsec-google-integration`
(Infra Manager root: `infrastructure-manager/palo-alto-waf`). Its `function_source/` is a copy
of this directory — keep the two in sync.

## Deploy (manual, for a dev loop)

```sh
gcloud functions deploy streamsec-waf-poller --gen2 --region=$REGION --runtime=python312 \
  --source=. --entry-point=poll --trigger-http --no-allow-unauthenticated \
  --service-account=$SA_EMAIL --timeout=300s --memory=512Mi \
  --set-env-vars=API_URL=$API_URL --set-secrets=API_TOKEN=$TOKEN_SECRET:latest \
  --vpc-connector=$CONNECTOR --egress-settings=private-ranges-only

# The function does no auth of its own: the Scheduler job's OIDC service account must be
# the only principal holding roles/run.invoker on the underlying Cloud Run service.
gcloud run services add-iam-policy-binding streamsec-waf-poller --region=$REGION \
  --member=serviceAccount:$SA_EMAIL --role=roles/run.invoker

gcloud scheduler jobs create http streamsec-waf-poll --location=$REGION --schedule='*/5 * * * *' \
  --uri="$(gcloud functions describe streamsec-waf-poller --gen2 --region=$REGION --format='value(serviceConfig.uri)')" \
  --http-method=POST --oidc-service-account-email=$SA_EMAIL --attempt-deadline=330s
```

`--attempt-deadline` sits above the function `--timeout` so a run that hits the function
deadline surfaces as the function's own 500, not as a Scheduler deadline miss.

The VPC connector is required when the firewall management interfaces sit on private
VPC addresses; egress `private-ranges-only` keeps the Stream API call on the public path.
