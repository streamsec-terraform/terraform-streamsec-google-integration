# GKE audit logs (real-time)

Sends GKE audit logs to Stream Security in real time: log sink, Pub/Sub topic, and a Cloud Function (gen2) that forwards each entry.

Two modes, set by `org_level_sink`:

- `true`: one organization sink, topic, and function in `project_for_resources`. Needs `organization_id`.
- `false`: one project sink, topic, and function in each project of `projects` (narrowed by `include_projects`).

Resource names end with one random suffix per module instance (`-<8 hex>`), e.g. `stream-sec-gke-logs-pubsub-0a1b2c3d`.

Cluster and project lists are Terraform inputs; `setup-prerequisites.sh` does not set them.

Set `build_service_account` if the project's default compute account cannot build the function (new projects get no automatic grants).

Upgrading from the old bucket-based GKE module: see the root README.

Org mode collects every project in the organization (also projects excluded from the integration) unless `include_projects` is set (root: `gke_include_projects`); cluster names match in every project.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.13 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.10 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.13 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.10 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_cloud_run_v2_service_iam_member.invoker](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_run_v2_service_iam_member) | resource |
| [google_cloudfunctions2_function.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloudfunctions2_function) | resource |
| [google_logging_organization_sink.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/logging_organization_sink) | resource |
| [google_logging_project_sink.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/logging_project_sink) | resource |
| [google_project_service.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_pubsub_topic.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_member.sink_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_secret_manager_secret.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_version.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_service_account.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.pubsub_token_creator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [random_id.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [terraform_data.inputs](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [time_sleep.api_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [streamsec_gcp_project.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/gcp_project) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_acked_project_ids"></a> [acked\_project\_ids](#input\_acked\_project\_ids) | Project ID per integrated project, unknown until its Stream Security ack exists (defers the token lookup of new projects only). | `map(string)` | n/a | yes |
| <a name="input_build_service_account"></a> [build\_service\_account](#input\_build\_service\_account) | Service account that builds the function (projects/<project>/serviceAccounts/<email>); {project} is replaced by each deploy project ID. Null uses the project default. | `string` | `null` | no |
| <a name="input_exclude_clusters"></a> [exclude\_clusters](#input\_exclude\_clusters) | Cluster names to skip. | `list(string)` | `[]` | no |
| <a name="input_include_clusters"></a> [include\_clusters](#input\_include\_clusters) | Cluster names to collect. Empty means all clusters. | `list(string)` | `[]` | no |
| <a name="input_include_projects"></a> [include\_projects](#input\_include\_projects) | GKE projects (subset of projects). Empty means all integrated projects (org mode: the whole organization). | `list(string)` | `[]` | no |
| <a name="input_org_level_sink"></a> [org\_level\_sink](#input\_org\_level\_sink) | true: one organization sink and one deployment in project\_for\_resources. false: a sink and a deployment in each GKE project. | `bool` | n/a | yes |
| <a name="input_organization_id"></a> [organization\_id](#input\_organization\_id) | GCP organization ID. Required when org\_level\_sink is true. | `string` | `null` | no |
| <a name="input_project_for_resources"></a> [project\_for\_resources](#input\_project\_for\_resources) | Org mode: integrated project that holds the topic, function and secret. | `string` | `""` | no |
| <a name="input_projects"></a> [projects](#input\_projects) | Integrated projects. | <pre>map(object({<br/>    project_id = string<br/>    name       = string<br/>  }))</pre> | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | Function and trigger region. | `string` | `"us-central1"` | no |
| <a name="input_secret_name"></a> [secret\_name](#input\_secret\_name) | Secret Manager secret name for the Stream Security token. Null: streamsec-gke-logs-token-<random suffix>. | `string` | `null` | no |
| <a name="input_source_bucket"></a> [source\_bucket](#input\_source\_bucket) | Bucket with the function source zip. | `string` | `"streamsec-production-public-artifacts"` | no |
| <a name="input_source_object"></a> [source\_object](#input\_source\_object) | Function source zip object name. | `string` | `"gcp-gke-logs-collection.zip"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_function_names"></a> [function\_names](#output\_function\_names) | Function name per deployment project. |
| <a name="output_secret_ids"></a> [secret\_ids](#output\_secret\_ids) | Token secret ID per deployment project. |
| <a name="output_service_account_emails"></a> [service\_account\_emails](#output\_service\_account\_emails) | Function service account email per deployment project. |
| <a name="output_sink_names"></a> [sink\_names](#output\_sink\_names) | Log sink name per deployment project. |
| <a name="output_sink_writer_identities"></a> [sink\_writer\_identities](#output\_sink\_writer\_identities) | Log sink writer identity per deployment project. |
| <a name="output_topic_ids"></a> [topic\_ids](#output\_topic\_ids) | Pub/Sub topic ID per deployment project. |
<!-- END_TF_DOCS -->
