<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.10 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.10 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_cloudfunctions2_function.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloudfunctions2_function) | resource |
| [google_logging_organization_sink.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/logging_organization_sink) | resource |
| [google_logging_project_sink.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/logging_project_sink) | resource |
| [google_project_iam_member.event_receiving](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.invoking](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_pubsub_topic.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_binding.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_binding) | resource |
| [google_secret_manager_regional_secret.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_regional_secret) | resource |
| [google_secret_manager_regional_secret_iam_member.function_secret_access](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_regional_secret_iam_member) | resource |
| [google_secret_manager_regional_secret_version.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_regional_secret_version) | resource |
| [google_service_account.function_service_account](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_client_config.current](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [streamsec_gcp_project.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/gcp_project) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_function_entry_point"></a> [function\_entry\_point](#input\_function\_entry\_point) | The entry point of the Cloud Function to create. | `string` | `"streamsec-audit-logs-collector"` | no |
| <a name="input_function_name"></a> [function\_name](#input\_function\_name) | The name of the Cloud Function to create. | `string` | `"stream-security-events-function"` | no |
| <a name="input_function_runtime"></a> [function\_runtime](#input\_function\_runtime) | The runtime of the Cloud Function to create. | `string` | `"nodejs22"` | no |
| <a name="input_function_service_account_description"></a> [function\_service\_account\_description](#input\_function\_service\_account\_description) | The description of the service account to create for the Cloud Function. | `string` | `"Service account for Stream Security events collection Cloud Function"` | no |
| <a name="input_function_service_account_display_name"></a> [function\_service\_account\_display\_name](#input\_function\_service\_account\_display\_name) | The display name of the service account to create for the Cloud Function. | `string` | `"Stream Security Events Function Service Account"` | no |
| <a name="input_function_service_account_id"></a> [function\_service\_account\_id](#input\_function\_service\_account\_id) | The ID of the service account to create for the Cloud Function. | `string` | `"stream-security-function-sa"` | no |
| <a name="input_function_timeout"></a> [function\_timeout](#input\_function\_timeout) | The timeout of the Cloud Function to create. | `number` | `5` | no |
| <a name="input_ingress_settings"></a> [ingress\_settings](#input\_ingress\_settings) | The ingress settings of the Cloud Function to create. | `string` | `"ALLOW_INTERNAL_ONLY"` | no |
| <a name="input_labels"></a> [labels](#input\_labels) | The labels to apply to the Stream Security GCP Project resources. | `map(string)` | `{}` | no |
| <a name="input_log_sink_filter"></a> [log\_sink\_filter](#input\_log\_sink\_filter) | The filter to apply to the log sink. (use only if you have more than 100 projects) | `string` | `""` | no |
| <a name="input_log_sink_name"></a> [log\_sink\_name](#input\_log\_sink\_name) | The name of the log sink to create. | `string` | `"stream-security-events-sink"` | no |
| <a name="input_org_level_sink"></a> [org\_level\_sink](#input\_org\_level\_sink) | If true, create a single org-level log sink, topic, and function. Otherwise, create per-project. | `bool` | `true` | no |
| <a name="input_organization_id"></a> [organization\_id](#input\_organization\_id) | The organization ID to use for org-level log sink. Required if org\_level\_sink is true. | `string` | `""` | no |
| <a name="input_project_for_resources"></a> [project\_for\_resources](#input\_project\_for\_resources) | The project ID to use for resources. Required if org\_level\_sink is true. | `string` | `""` | no |
| <a name="input_projects"></a> [projects](#input\_projects) | A list of projects to create Service Accounts for. | `any` | n/a | yes |
| <a name="input_pubsub_topic_name"></a> [pubsub\_topic\_name](#input\_pubsub\_topic\_name) | The name of the Pub/Sub topic to create. | `string` | `"stream-security-events-topic"` | no |
| <a name="input_secret_name"></a> [secret\_name](#input\_secret\_name) | The name of the secret in Secret Manager containing the API token. | `string` | `"stream-security-collection-token"` | no |
| <a name="input_source_archive_name"></a> [source\_archive\_name](#input\_source\_archive\_name) | The name of the archive containing the Cloud Function source code. | `string` | `"gcp-events-collection.zip"` | no |
| <a name="input_source_bucket_name"></a> [source\_bucket\_name](#input\_source\_bucket\_name) | The name of the bucket containing the Cloud Function source code. | `string` | `"streamsec-production-public-artifacts"` | no |
| <a name="input_topic_message_retention_duration"></a> [topic\_message\_retention\_duration](#input\_topic\_message\_retention\_duration) | The duration to retain messages in the Pub/Sub topic. | `string` | `"259200s"` | no |
| <a name="input_use_secret_manager"></a> [use\_secret\_manager](#input\_use\_secret\_manager) | Boolean to determine if the Secret Manager should be used to store the API token. | `bool` | `true` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
