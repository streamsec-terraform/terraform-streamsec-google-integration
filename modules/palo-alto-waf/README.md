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
- Post-deployment acknowledgement to Stream Security

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

## Deployment acknowledgement

After Terraform has created the function, its Cloud Run invoker binding, and
the Cloud Scheduler job, the module sends:

```text
POST <stream_api_url>/api/accounts/waf/waf-acknowledge
Authorization: <redacted stream_integration_token>
Content-Type: application/json

{"template_version":"<stream_template_version>"}
```

This uses the same endpoint, authentication header, and template-version field
as the AWS and Azure WAF templates. The backend idempotently sets the integration
status to `READY` and records the deployed template version. Terraform re-sends
the acknowledgement when the Scheduler, integration-token secret version,
Stream API URL, or template version changes.

The callback runs once on the Terraform/Infrastructure Manager runner with the
same two-minute bound as the Azure deployment script. As in AWS and Azure, it
fails the deployment if Stream does not return a successful HTTP response. A
failed callback therefore cannot report a successful deployment or leave a
newly deployed integration falsely marked ready; rerunning `terraform apply`
retries it.

The sensitive token is passed through the provisioner environment and curl
configuration on standard input. It is not included in Terraform outputs,
Terraform's command text, or process arguments; its existing sensitive input
and Secret Manager state contract is unchanged.

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
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.10 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.10 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_cloud_run_v2_service_iam_member.scheduler_invoker](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_run_v2_service_iam_member) | resource |
| [google_cloud_scheduler_job.poll](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_scheduler_job) | resource |
| [google_cloudfunctions2_function.collector](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloudfunctions2_function) | resource |
| [google_project_iam_custom_role.deployer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_member.build_artifact_writer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.build_log_writer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.build_source_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.deployer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_service.required](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_secret_manager_secret.integration_token](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.firewall_credentials](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_iam_member.integration_token](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_version.integration_token](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_service_account.build](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.collector](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_storage_bucket.source](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_object.function_source](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_object) | resource |
| [google_vpc_access_connector.collector](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/vpc_access_connector) | resource |
| [terraform_data.acknowledge](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.network_contract](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.network_scope_contract](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.secret_contract](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [time_sleep.api_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.build_iam_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.deployer_iam_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [archive_file.function_source](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [google_compute_network.selected](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_network) | data source |
| [google_compute_subnetwork.selected](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_subnetwork) | data source |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_connector_cidr"></a> [connector\_cidr](#input\_connector\_cidr) | Unused /28 IPv4 range allocated to the Serverless VPC Access connector. | `string` | `"10.10.9.0/28"` | no |
| <a name="input_deployment_service_account_email"></a> [deployment\_service\_account\_email](#input\_deployment\_service\_account\_email) | Optional Terraform deployment service account. When set, the module grants it a custom role containing only Cloud Run and Secret Manager get/set IAM policy so it can install the private function and secret bindings. Infrastructure Manager supplies its runner account. | `string` | `""` | no |
| <a name="input_firewall_secret_names"></a> [firewall\_secret\_names](#input\_firewall\_secret\_names) | Comma-delimited Secret Manager version resource names for firewall API keys, as emitted by the Lightlytics wizard. | `string` | `""` | no |
| <a name="input_function_timeout_seconds"></a> [function\_timeout\_seconds](#input\_function\_timeout\_seconds) | Cloud Function timeout. Scheduler allows 30 additional seconds so function failures surface directly. | `number` | `300` | no |
| <a name="input_labels"></a> [labels](#input\_labels) | Additional labels to apply to supported resources. | `map(string)` | `{}` | no |
| <a name="input_manage_apis"></a> [manage\_apis](#input\_manage\_apis) | Whether to enable the Google APIs required by this deployment. | `bool` | `true` | no |
| <a name="input_poll_schedule"></a> [poll\_schedule](#input\_poll\_schedule) | Cloud Scheduler cron expression. One-, two-, or three-minute polling is allowed so downstream processing retains headroom within the five-minute product objective. | `string` | `"*/3 * * * *"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project in which to deploy the collector. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region for the function, VPC connector, source bucket, and Scheduler job. | `string` | `"us-central1"` | no |
| <a name="input_stream_api_url"></a> [stream\_api\_url](#input\_stream\_api\_url) | Stream Security tenant base URL. The integration token is sent only over HTTPS. | `string` | n/a | yes |
| <a name="input_stream_integration_token"></a> [stream\_integration\_token](#input\_stream\_integration\_token) | Stream Security Palo Alto integration token. Stored in Secret Manager and mounted into the function. | `string` | n/a | yes |
| <a name="input_stream_template_version"></a> [stream\_template\_version](#input\_stream\_template\_version) | Release ref used by Infrastructure Manager and recorded by the deployment acknowledgement. | `string` | `""` | no |
| <a name="input_subnet"></a> [subnet](#input\_subnet) | Subnet name or self-link selected by the wizard. It must belong to vpc\_network. | `string` | n/a | yes |
| <a name="input_vpc_network"></a> [vpc\_network](#input\_vpc\_network) | VPC network name or self-link that can route to the Palo Alto management interface. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_build_service_account_email"></a> [build\_service\_account\_email](#output\_build\_service\_account\_email) | Dedicated service account used to build the Cloud Function image. |
| <a name="output_deployment_id"></a> [deployment\_id](#output\_deployment\_id) | Infrastructure Manager deployment identifier used by the Lightlytics wizard. |
| <a name="output_function_name"></a> [function\_name](#output\_function\_name) | Name of the deployed Cloud Function. |
| <a name="output_function_uri"></a> [function\_uri](#output\_function\_uri) | IAM-protected URI invoked by Cloud Scheduler. |
| <a name="output_project_id"></a> [project\_id](#output\_project\_id) | GCP project hosting the deployment. |
| <a name="output_region"></a> [region](#output\_region) | GCP region hosting the deployment. |
| <a name="output_scheduler_name"></a> [scheduler\_name](#output\_scheduler\_name) | Name of the Cloud Scheduler polling job. |
| <a name="output_scheduler_schedule"></a> [scheduler\_schedule](#output\_scheduler\_schedule) | Effective Cloud Scheduler cron expression. |
| <a name="output_service_account_email"></a> [service\_account\_email](#output\_service\_account\_email) | Runtime and Scheduler OIDC service account. |
| <a name="output_stream_template_version"></a> [stream\_template\_version](#output\_stream\_template\_version) | Release ref supplied by the deployment command. |
| <a name="output_vpc_connector_id"></a> [vpc\_connector\_id](#output\_vpc\_connector\_id) | Serverless VPC Access connector used for private firewall management traffic. |
<!-- END_TF_DOCS -->
