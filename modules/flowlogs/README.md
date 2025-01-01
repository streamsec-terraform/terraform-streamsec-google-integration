<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.8 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.8 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_cloudfunctions_function.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloudfunctions_function) | resource |
| [streamsec_gcp_project.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/gcp_project) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_function_entry_point"></a> [function\_entry\_point](#input\_function\_entry\_point) | The entry point of the Cloud Function to create. | `string` | `"StorageFlowlogsCollection"` | no |
| <a name="input_function_name"></a> [function\_name](#input\_function\_name) | The name of the Cloud Function to create. | `string` | `"stream-security-flowlogs-function"` | no |
| <a name="input_function_runtime"></a> [function\_runtime](#input\_function\_runtime) | The runtime of the Cloud Function to create. | `string` | `"nodejs20"` | no |
| <a name="input_function_timeout"></a> [function\_timeout](#input\_function\_timeout) | The timeout of the Cloud Function to create. | `number` | `5` | no |
| <a name="input_ingress_settings"></a> [ingress\_settings](#input\_ingress\_settings) | The ingress settings of the Cloud Function to create. | `string` | `"ALLOW_INTERNAL_ONLY"` | no |
| <a name="input_labels"></a> [labels](#input\_labels) | The labels to apply to the Stream Security GCP Project resources. | `map(string)` | `{}` | no |
| <a name="input_projects"></a> [projects](#input\_projects) | A list of projects to create Service Accounts for. | `any` | n/a | yes |
| <a name="input_source_archive_name"></a> [source\_archive\_name](#input\_source\_archive\_name) | The name of the archive containing the Cloud Function source code. | `string` | `"gcp-flow-logs-collection.zip"` | no |
| <a name="input_source_bucket_name"></a> [source\_bucket\_name](#input\_source\_bucket\_name) | The name of the bucket containing the Cloud Function source code. | `string` | `"streamsec-production-public-artifacts"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
