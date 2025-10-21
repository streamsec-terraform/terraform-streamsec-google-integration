# StreamSec - Google Integration using Terraform
Terraform module for google integration with Stream Security.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.13 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.10 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.13 |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.10 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_flowlogs"></a> [flowlogs](#module\_flowlogs) | ./modules/flowlogs | n/a |
| <a name="module_real_time_events"></a> [real\_time\_events](#module\_real\_time\_events) | ./modules/real-time-events | n/a |
| <a name="module_response"></a> [response](#module\_response) | ./modules/response | n/a |

## Resources

| Name | Type |
|------|------|
| [google_organization_iam_member.security_reviewer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/organization_iam_member) | resource |
| [google_organization_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/organization_iam_member) | resource |
| [google_service_account.org](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_key.org](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_key) | resource |
| [streamsec_gcp_project.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/gcp_project) | resource |
| [streamsec_gcp_project_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/gcp_project_ack) | resource |
| [time_sleep.this](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [google_cloud_asset_search_all_resources.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/cloud_asset_search_all_resources) | data source |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [google_service_account.existing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/service_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_auto_grant_workflow_invoker"></a> [auto\_grant\_workflow\_invoker](#input\_auto\_grant\_workflow\_invoker) | If true, automatically grant roles/workflows.invoker permission to the specified service account. | `bool` | `true` | no |
| <a name="input_create_sa"></a> [create\_sa](#input\_create\_sa) | Boolean to determine if the Service Account should be created. If false, the existing service account must have organization level permissions. | `bool` | `true` | no |
| <a name="input_enable_real_time_events"></a> [enable\_real\_time\_events](#input\_enable\_real\_time\_events) | Boolean to determine if Real Time Events should be enabled. | `bool` | `true` | no |
| <a name="input_exclude_projects"></a> [exclude\_projects](#input\_exclude\_projects) | A list of projects to exclude from the Organization Integration. | `list(string)` | `[]` | no |
| <a name="input_exclude_runbooks"></a> [exclude\_runbooks](#input\_exclude\_runbooks) | List of response runbook names to exclude from deployment. Useful for disabling specific remediations. | `list(string)` | `[]` | no |
| <a name="input_existing_sa_json_file_path"></a> [existing\_sa\_json\_file\_path](#input\_existing\_sa\_json\_file\_path) | The path to the JSON file for the existing Service Account. | `string` | `null` | no |
| <a name="input_include_projects"></a> [include\_projects](#input\_include\_projects) | A list of projects to include from the Organization Integration. If not set, all projects will be included. | `list(string)` | `[]` | no |
| <a name="input_log_sink_filter"></a> [log\_sink\_filter](#input\_log\_sink\_filter) | The filter to apply to the log sink. (use only if you have more than 100 projects) | `string` | `""` | no |
| <a name="input_org_id"></a> [org\_id](#input\_org\_id) | The Organization ID to create the Service Account in (REQUIRED if create\_sa is true). | `string` | `null` | no |
| <a name="input_org_level_sink"></a> [org\_level\_sink](#input\_org\_level\_sink) | If true, create a single org-level log sink, topic, and function. Otherwise, create per-project. | `bool` | `true` | no |
| <a name="input_project_for_resources"></a> [project\_for\_resources](#input\_project\_for\_resources) | The project ID to use for resources. Required if org\_level\_sink is true. | `string` | `""` | no |
| <a name="input_project_for_sa"></a> [project\_for\_sa](#input\_project\_for\_sa) | The project to create the Service Account in (if not set and create\_sa is true, will take provider project id). | `string` | `null` | no |
| <a name="input_regional_secret"></a> [regional\_secret](#input\_regional\_secret) | If true, create a regional secret in Secret Manager containing the API token. If false, create a global secret in Secret Manager containing the API token. | `bool` | `true` | no |
| <a name="input_response_enabled_projects"></a> [response\_enabled\_projects](#input\_response\_enabled\_projects) | A list of project IDs to create response resources for. | `list(string)` | `[]` | no |
| <a name="input_response_org_level_permissions"></a> [response\_org\_level\_permissions](#input\_response\_org\_level\_permissions) | If true, create response service accounts and custom roles at organization level. If false, create them at project level. | `bool` | `true` | no |
| <a name="input_sa_account_id"></a> [sa\_account\_id](#input\_sa\_account\_id) | The account ID for the Service Account to be created for Stream Security. | `string` | `"stream-security"` | no |
| <a name="input_sa_description"></a> [sa\_description](#input\_sa\_description) | The description for the Service Account to be created for Stream Security. | `string` | `"Stream Security Service Account"` | no |
| <a name="input_sa_display_name"></a> [sa\_display\_name](#input\_sa\_display\_name) | The display name for the Service Account to be created for Stream Security. | `string` | `"Stream Security"` | no |
| <a name="input_secret_name"></a> [secret\_name](#input\_secret\_name) | The name of the Secret Manager secret to store the API token. | `string` | `"stream-security-collection-token"` | no |
| <a name="input_use_secret_manager"></a> [use\_secret\_manager](#input\_use\_secret\_manager) | Boolean to determine if the Secret Manager should be used to store the API token. | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_projects"></a> [projects](#output\_projects) | The projects map |
<!-- END_TF_DOCS -->
