# Stream Security — GCP hub volume scanner: access to other projects

Gives a hub's volume scanner access to the other projects of the organization
with your own Terraform, instead of the gcloud command Stream's console
renders. The [module README](../../modules/volume-scanner-hub-access/README.md)
says which rights you need, what the grant allows, and what to do if the
console's command already ran in the organization.

## Run

After the hubs' volume scanners are deployed, as an organization admin:

```sh
gcloud auth application-default login
terraform init
terraform apply -var='hub_project_ids=["<HUB_PROJECT_ID>"]' -var=org_id=<ORG_ID>
```

`gcloud projects get-ancestors <HUB_PROJECT_ID>` shows the organization's ID.
To grant on folders or projects instead of the whole organization, set
`grant_on` in `main.tf`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_scanner_hub_access"></a> [scanner\_hub\_access](#module\_scanner\_hub\_access) | ../../modules/volume-scanner-hub-access | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_create_role"></a> [create\_role](#input\_create\_role) | Create and manage the organization's streamsecVolumeScannerTarget role. False when Stream's console command created it, or another stack manages it. | `bool` | `true` | no |
| <a name="input_hub_project_ids"></a> [hub\_project\_ids](#input\_hub\_project\_ids) | The projects whose volume scanner also scans the other projects of the organization. | `set(string)` | n/a | yes |
| <a name="input_org_id"></a> [org\_id](#input\_org\_id) | The organization's numeric ID. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_granted_on"></a> [granted\_on](#output\_granted\_on) | Where the role is granted. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | The organization custom role granted to the hubs' scanners. |
| <a name="output_scanner_service_account_emails"></a> [scanner\_service\_account\_emails](#output\_scanner\_service\_account\_emails) | The hubs' scanner service accounts the role is granted to. |
<!-- END_TF_DOCS -->
