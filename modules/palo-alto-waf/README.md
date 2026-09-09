# Stream Security Palo Alto NGFW collector (GCP)

Deploys the Lightlytics/Stream Security NGFW collector as an IAM-protected
second-generation Cloud Function. Cloud Scheduler invokes the function with
OIDC, the function reaches private firewall management addresses through
Serverless VPC Access, and public Stream API traffic continues over the
platform's normal internet egress path.

## Resources

- Required Google APIs
- Dedicated runtime/Scheduler and build service accounts
- Four-permission custom role allowing the Infrastructure Manager runner to
  install Cloud Run and Secret Manager IAM policies
- Secret Manager secret for the Stream integration token
- Secret-scoped `roles/secretmanager.secretAccessor` grants for the selected
  firewall API-key versions
- Serverless VPC Access connector on the selected VPC
- Private Python 3.12 Cloud Function (`poll`)
- Source archive bucket with seven-day object retention
- Cloud Scheduler HTTP job with OIDC and one bounded retry

The function uses `PRIVATE_RANGES_ONLY` connector egress: RFC 1918/private
firewall management traffic traverses the selected VPC, while the public Stream
API remains reachable without requiring Cloud NAT on that VPC.

The selected VPC and subnet must belong to `project_id`, and the subnet must be
in `region`. Shared VPC service projects need a dedicated `/28` connector subnet
in the host project plus host-project IAM and firewall preparation; the wizard
does not currently supply that distinct subnet contract, so this module rejects
cross-project network links rather than creating a connector that cannot work.

## Infrastructure Manager

The Lightlytics wizard applies `infrastructure-manager/palo-alto-waf`, a thin
root around this module. Its generated command supplies these scalar values:

| Input | Representation |
|---|---|
| `project_id` | GCP project ID |
| `region` | GCP region; wizard default `us-central1` |
| `stream_api_url` | HTTPS tenant base URL |
| `stream_integration_token` | Sensitive integration token |
| `stream_template_version` | Git release ref |
| `vpc_network` | Network name or self-link |
| `subnet` | Subnet name or self-link |
| `connector_cidr` | IPv4 `/28`; wizard default `10.10.9.0/28` |
| `firewall_secret_names` | Comma-delimited Secret Manager version names |

`firewall_secret_names` is deliberately a string at the Infrastructure Manager
boundary because the wizard passes it as one comma-delimited scalar inside
`--input-values`.

The wizard currently defaults `stream_template_version` and
`--git-source-ref` to `v2.10.0`. That ref does not exist yet. The consumer must
point to a real tag or commit containing this module before a deployment can
succeed; this module does not create or publish release tags.

## Polling objective

The default schedule is `*/3 * * * *`. A three-minute trigger cadence leaves
roughly two minutes for collection and downstream processing toward the
five-minute UI reflection objective. Cron controls only trigger timing, so it
cannot by itself guarantee an end-to-end SLA; firewall response time, function
execution, retries, and downstream processing also contribute.

The schedule is configurable, but validation limits it to every one, two, or
three minutes so a deployment cannot silently violate that timing objective.

## Secret handling and IAM

The Stream integration token is sensitive Terraform input, written to a
dedicated Secret Manager secret, and mounted as the `API_TOKEN` secret
environment variable. Firewall API keys remain in their existing secrets. The
function service account receives `secretAccessor` only on the integration
secret and the explicitly listed firewall secrets. No token or API key is
included in outputs or plaintext function environment variables.

The function has no application-level authentication. Only the dedicated
service account receives `roles/run.invoker` on its backing Cloud Run service,
and Scheduler uses that identity to mint the OIDC token.

Cloud Build uses a separate service account instead of a legacy or default
Compute service account. It receives only `roles/logging.logWriter`,
`roles/artifactregistry.writer`, and `roles/storage.objectViewer`, the roles
Google documents for custom Cloud Run functions build identities. The latter
two grants are conditioned to Cloud Functions repositories and source buckets,
so the builder cannot read unrelated bucket objects or modify unrelated
Artifact Registry repositories. This keeps deployment working in projects where
automatic default-service-account grants are disabled.

On first deployment, the module waits two minutes after writing those three
project IAM bindings before creating the function. Google documents two minutes
as the typical propagation time for allow-policy changes, and the Cloud
Functions provider does not retry a build that starts before the permissions
become effective.

The #22440 setup gives the Infra Manager runner `roles/editor`,
`roles/iam.roleAdmin`, `roles/resourcemanager.projectIamAdmin`, and
`roles/config.agent`. Editor includes `iam.serviceAccounts.actAs`, but those
roles do not include `run.services.setIamPolicy` or
`secretmanager.secrets.setIamPolicy`. The Infrastructure Manager root therefore
supplies the runner email to this module, which grants a custom role containing
only the get/set IAM policy permissions for Cloud Run services and Secret
Manager secrets. This avoids requiring project-wide `roles/run.admin` or
`roles/secretmanager.admin`.

Google grants `roles/cloudscheduler.serviceAgent` to the Scheduler service agent
when the API is enabled. The module deliberately does not own that shared,
project-wide grant: removing this deployment must not break other Scheduler
jobs. Projects that enabled Scheduler before March 19, 2019, or manually removed
the grant, must restore it as a project prerequisite or authenticated Scheduler
requests return `403`.

Firewall secrets must belong to `project_id` (the project ID or numeric project
number is accepted in each version name). The #22440 runner receives IAM
authority only in that project, so accepting cross-project secrets would make
the generated deployment fail while installing `secretAccessor`.

## Function-source synchronization

`function_source/` is copied without behavioral or dependency changes from:

```text
lightlytics/lightlytics@76e5e26420f7a1518b7d7524418de03ae0067c00:gcp/functions/waf-gcp/
```

When the upstream collector changes, replace the complete directory from an
immutable commit, compare all files, update the commit above, and validate both
Python import/compilation and Terraform packaging. Do not patch only one copy:
the Lightlytics source directory explicitly identifies this module as its
deployment copy.

The synchronized collector intentionally retains two upstream behaviors that
are outside this deployment module's scope: firewall TLS certificate checking
is disabled, and Palo/Stream HTTP calls do not set socket-level timeouts. The
Cloud Function timeout remains the outer bound. These should be addressed in
the canonical Lightlytics source first and then synchronized here.

## Direct module usage

```hcl
module "palo_alto_waf" {
  source  = "streamsec-terraform/google-integration/streamsec//modules/palo-alto-waf"
  version = "<release containing DEV-22491>"

  project_id               = "my-project"
  region                   = "us-central1"
  stream_api_url           = "https://acme.streamsec.io"
  stream_integration_token = var.stream_integration_token
  stream_template_version  = "<same release ref>"
  vpc_network              = "my-vpc"
  subnet                   = "my-firewall-subnet"
  connector_cidr           = "10.10.9.0/28"
  firewall_secret_names    = "projects/my-project/secrets/palo-api-key/versions/latest"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.5 |
| archive | >= 2.0 |
| google | >= 6.0 |
| time | >= 0.10 |

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|:---:|
| `project_id` | GCP project in which to deploy the collector. | `string` | n/a | yes |
| `region` | Region for the function, connector, source bucket, and Scheduler job. | `string` | `"us-central1"` | no |
| `stream_api_url` | HTTPS Stream Security tenant base URL. | `string` | n/a | yes |
| `stream_integration_token` | Sensitive Stream Security Palo Alto integration token. | `string` | n/a | yes |
| `stream_template_version` | Release ref used by Infrastructure Manager. | `string` | `""` | no |
| `vpc_network` | VPC network name or self-link that routes to the firewall. | `string` | n/a | yes |
| `subnet` | Wizard-selected subnet name or self-link; must belong to the VPC. | `string` | n/a | yes |
| `connector_cidr` | Unused IPv4 `/28` for Serverless VPC Access. | `string` | `"10.10.9.0/28"` | no |
| `firewall_secret_names` | Comma-delimited Secret Manager version resource names. | `string` | `""` | no |
| `poll_schedule` | One-, two-, or three-minute Scheduler cron expression. | `string` | `"*/3 * * * *"` | no |
| `function_timeout_seconds` | Function timeout; Scheduler adds 30 seconds. | `number` | `300` | no |
| `manage_apis` | Enable APIs required by the deployment. | `bool` | `true` | no |
| `deployment_service_account_email` | Optional deployer granted only Cloud Run and Secret Manager get/set IAM policy; set by the Infrastructure Manager root. | `string` | `""` | no |
| `labels` | Additional labels for supported resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `deployment_id` | Infrastructure Manager deployment identifier. |
| `project_id` | GCP project hosting the deployment. |
| `region` | GCP region hosting the deployment. |
| `stream_template_version` | Release ref supplied by the deployment command. |
| `function_name` | Deployed Cloud Function name. |
| `function_uri` | IAM-protected function URI. |
| `service_account_email` | Runtime and Scheduler OIDC service account. |
| `build_service_account_email` | Dedicated Cloud Function build service account. |
| `scheduler_name` | Cloud Scheduler polling job name. |
| `scheduler_schedule` | Effective polling cron expression. |
| `vpc_connector_id` | Serverless VPC Access connector ID. |
<!-- END_TF_DOCS -->
