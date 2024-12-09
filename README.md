# StreamSec - GCP Project Integration using Terraform
Terraform module for gcp project

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.7 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.7 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_project_iam_member.security_reviewer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_key.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_key) | resource |
| [streamsec_gcp_project.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/gcp_project) | resource |
| [streamsec_gcp_project_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/gcp_project_ack) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_projects"></a> [projects](#input\_projects) | A list of projects to create Service Accounts for. | `any` | `{}` | no |
| <a name="input_sa_account_id"></a> [sa\_account\_id](#input\_sa\_account\_id) | The account ID for the Service Account to be created for Stream Security. | `string` | `"stream-security"` | no |
| <a name="input_sa_description"></a> [sa\_description](#input\_sa\_description) | The description for the Service Account to be created for Stream Security. | `string` | `"Stream Security Service Account"` | no |
| <a name="input_sa_display_name"></a> [sa\_display\_name](#input\_sa\_display\_name) | The display name for the Service Account to be created for Stream Security. | `string` | `"Stream Security"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_projects"></a> [projects](#output\_projects) | The projects map |
<!-- END_TF_DOCS -->