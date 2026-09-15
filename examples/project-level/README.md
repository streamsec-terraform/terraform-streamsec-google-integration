# Stream Security — GCP Project-Level Integration

Integrates a single GCP project without any organization-level permissions.
Use this when the engineer running Terraform has `roles/owner` on one project
and cannot be granted anything at the organization.

For the standard organization-wide integration, see [`../basic`](../basic).

## How it differs from the org integration

| | Org integration | This example |
|---|---|---|
| Reader roles granted on | the organization | each listed project |
| `org_id` | required | not set |
| Project discovery | Cloud Asset, org-scoped | explicit `include_projects` |
| Log sink | one org sink | one sink per project |

The switch is `sa_project_level_permissions = true`, which grants
`roles/viewer` and `roles/iam.securityReviewer` to the Stream Security service
account on every project in `include_projects` instead of on the organization.
That variable requires `include_projects`, since there is no org-wide project
discovery to fall back on.

## Prerequisites

- `roles/owner` on the project (or `roles/editor` + `roles/iam.roleAdmin` +
  `roles/resourcemanager.projectIamAdmin`).
- The module creates a JSON key for the Stream Security service account. If the
  organization policy `iam.disableServiceAccountKeyCreation` is enforced on the
  project, either have an organization admin lift it for this project (or grant
  you `roles/orgpolicy.policyAdmin` on the project), or skip key creation by
  setting `create_sa = false` and `existing_sa_json_file_path` to a key an admin
  created for you. In that case the service account must already hold
  `roles/viewer` and `roles/iam.securityReviewer` on each project in
  `include_projects`.

## What gets deployed

- One Stream Security service account and key, in `project_for_sa` (or the
  provider project), with Viewer + Security Reviewer bound on every project in
  `include_projects`
- Per project in `include_projects`: a Pub/Sub topic, a project-level log sink, a
  Gen2 Cloud Function for real-time events, and a Secret Manager secret holding
  the collection token

## Trade-offs

The service account can only see what lives at or below the project, so these
are not collected:

- Organization- and folder-level IAM bindings. Permissions a principal inherits
  from above the project will not appear as effective permissions.
- Organization policies and other resources that live at the organization or
  folder level.

Account acknowledgement and scanning still succeed; organization-scoped
resource types are simply not collected.

To cover more projects, add them to `include_projects` and grant the deployer
`roles/owner` on each, or run this configuration once per project.

## Run

```sh
terraform init
terraform apply
```
