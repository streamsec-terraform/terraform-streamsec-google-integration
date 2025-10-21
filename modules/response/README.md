# GCP Response Module

This module creates Google Cloud Workflows for Stream Security remediation actions, along with the necessary service accounts and IAM roles.

## Features

- **Automated Workflow Creation**: Creates Google Cloud Workflows for each GCP remediation defined in the runbook configuration
- **Flexible Service Account Management**: Supports both organization-level and project-level service accounts
- **Custom IAM Roles**: Automatically creates custom IAM roles based on remediation requirements
- **Least Privilege Access**: Each workflow uses a dedicated service account with only the necessary permissions

## Usage

### Organization-Level Service Accounts (Default)

When `org_level_permissions` is set to `true` (default), the module creates:
- One service account per remediation type (shared across all projects)
- Custom IAM roles at the organization level
- IAM bindings that grant organization-wide access

This approach is more efficient and easier to manage when working with multiple projects.

```hcl
module "response" {
  source = "./modules/response"

  projects = {
    project1 = {
      project_id = "my-project-1"
    }
    project2 = {
      project_id = "my-project-2"
    }
  }

  org_level_permissions = true
  organization_id       = "123456789012"

  # Optionally exclude specific runbooks
  exclude_runbooks = [
    "StreamSecurityGcpStopVm",
    "StreamSecurityGcpRestartVm"
  ]
}
```

### Project-Level Service Accounts

When `org_level_permissions` is set to `false`, the module creates:
- One service account per project-remediation combination
- Custom IAM roles at the project level
- IAM bindings scoped to individual projects

This approach provides more isolation and is useful when you need strict project-level access control.

```hcl
module "response" {
  source = "./modules/response"

  projects = {
    project1 = {
      project_id = "my-project-1"
    }
    project2 = {
      project_id = "my-project-2"
    }
  }

  org_level_permissions = false
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| projects | A map of projects to create response resources for | `map(any)` | n/a | yes |
| org_level_permissions | If true, create service accounts and custom roles at organization level. If false, create them at project level. | `bool` | `true` | no |
| organization_id | The organization ID to use for org-level service accounts and roles. Required if org_level_permissions is true. | `string` | `""` | no |
| exclude_runbooks | List of runbook names to exclude from deployment. Useful for disabling specific remediations. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| workflows | Map of created workflow resources |
| service_accounts_org | Map of organization-level service accounts created for remediations |
| service_accounts_project | Map of project-level service accounts created for remediations |
| custom_roles_org | Map of organization-level custom roles created for remediations |
| custom_roles_project | Map of project-level custom roles created for remediations |
| role_suffix | Random suffix appended to custom role IDs to avoid conflicts with pending deletions |

## How It Works

1. **Runbook Configuration**: The module reads remediation configurations from `templates/runbook_config.yaml`
2. **Role Definition**: Each remediation references a role file in `templates/gcp_roles/` that defines required permissions
3. **Resource Creation**:
   - Creates custom IAM roles based on the role definitions
   - Creates service accounts for executing the remediations
   - Assigns the custom roles to the service accounts
   - Creates workflows that use the service accounts

## Remediation Configuration

Each remediation in the runbook configuration should include:

```yaml
- name: StreamSecurityGcpStopVm
  description: Stop the Compute Engine VM instance.
  cloud_provider: gcp
  resource_type: gcp_vm_instance
  role_name: customStopVmRole
  role_file: gcp_stop_vm_role.json
  Parameters:
    - name: VmId
      type: String
```

The corresponding role file (`gcp_stop_vm_role.json`) defines the required permissions:

```json
{
  "includedPermissions": [
    "compute.instances.stop",
    "logging.logEntries.create"
  ],
  "name": "projects/${projectId}/roles/customResetVmRole",
  "title": "GCP Stream Stop VM Role"
}
```

## Requirements

- Terraform >= 0.13
- Google Cloud Provider
- Organization-level permissions (if using org_level_permissions = true)

## Notes

- Service account IDs are automatically generated from remediation names (lowercase, alphanumeric with hyphens)
  - "StreamSecurityGcp" prefix is replaced with "streamsec" for shorter names
- Custom role IDs include a random suffix to avoid conflicts with GCP's 7-day soft-delete period for custom roles
  - This allows for immediate redeployment after deletion
  - To force recreation of all roles, change the `role_version` keeper in the `random_id` resource
- Workflows depend on service accounts and IAM bindings being created first
- Use `exclude_runbooks` to selectively disable specific remediations without modifying the source configuration


<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.13 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.13 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_organization_iam_custom_role.remediation_roles_org](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/organization_iam_custom_role) | resource |
| [google_organization_iam_member.sa_role_binding_org](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/organization_iam_member) | resource |
| [google_project_iam_custom_role.remediation_roles_project](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_member.sa_role_binding_project](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.remediation_sa_org](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.remediation_sa_project](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_workflows_workflow.gcp_remediations](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/workflows_workflow) | resource |
| [random_id.role_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [streamsec_gcp_response_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/gcp_response_ack) | resource |
| [google_client_config.current](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_exclude_runbooks"></a> [exclude\_runbooks](#input\_exclude\_runbooks) | List of runbook names to exclude from deployment. Useful for disabling specific remediations. | `list(string)` | `[]` | no |
| <a name="input_org_level_permissions"></a> [org\_level\_permissions](#input\_org\_level\_permissions) | If true, create service accounts and custom roles at organization level. If false, create them at project level. | `bool` | `true` | no |
| <a name="input_organization_id"></a> [organization\_id](#input\_organization\_id) | The organization ID to use for org-level service accounts and roles. Required if org\_level\_permissions is true. | `string` | `""` | no |
| <a name="input_projects"></a> [projects](#input\_projects) | A list of project IDs to create response resources for. | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_custom_roles_org"></a> [custom\_roles\_org](#output\_custom\_roles\_org) | Map of organization-level custom roles created for remediations |
| <a name="output_custom_roles_project"></a> [custom\_roles\_project](#output\_custom\_roles\_project) | Map of project-level custom roles created for remediations |
| <a name="output_role_suffix"></a> [role\_suffix](#output\_role\_suffix) | Random suffix appended to custom role IDs to avoid conflicts with pending deletions |
| <a name="output_service_accounts_org"></a> [service\_accounts\_org](#output\_service\_accounts\_org) | Map of organization-level service accounts created for remediations |
| <a name="output_service_accounts_project"></a> [service\_accounts\_project](#output\_service\_accounts\_project) | Map of project-level service accounts created for remediations |
| <a name="output_workflows"></a> [workflows](#output\_workflows) | Map of created workflow resources |
<!-- END_TF_DOCS -->
