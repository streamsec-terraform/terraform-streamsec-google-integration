## Stream Security volume scanner: a hub's access to other projects (GCP)

A **hub** is a project whose volume scanner ([`modules/volume-scanner`](../volume-scanner))
also scans other projects of the organization, the ones chosen in Stream.
Snapshots and scan disks stay in the hub. In the projects it scans, the hub's
scanner only reads, and snapshots each disk into the hub.

This module gives the hub's scanner that access: one organization custom role,
`streamsecVolumeScannerTarget`, granted to its service account,
`streamsec-volume-scanner@<hub project>.iam.gserviceaccount.com`, on the
organization, on folders, or on projects. It does what the gcloud command in
Stream's console does when you set up a hub, for organizations that manage IAM
with their own Terraform. Use one or the other; see
[If the console's command already ran](#if-the-consoles-command-already-ran).

### What this module creates

- The organization custom role `streamsecVolumeScannerTarget`, titled "Stream
  Security volume scanner: scanned projects", at stage GA, with the
  [permissions below](#what-the-grant-allows).
- One IAM member binding of that role to the scanner's service account: on the
  organization, on each folder, or on each project. The bindings are
  non-authoritative, so they leave every other binding in those policies alone.

Nothing is created in the hub or in the projects it scans.

It is not part of the scanner's Infrastructure Manager deployment on purpose:
Infra Manager's service account would then hold org Role Admin and org IAM
admin for as long as the deployment exists. Run this module yourself, as
someone who holds them.

### Usage

Apply it after the hub's scanner is deployed: IAM refuses a binding to a
service account that doesn't exist yet. `grant_on` takes exactly one of the
three forms below.

#### The whole organization (default)

Every project of the organization, including ones created later.

```hcl
module "scanner_hub_access" {
  source  = "streamsec-terraform/google-integration/streamsec//modules/volume-scanner-hub-access"
  version = "~> 2.22"

  hub_project_id = "my-scanner-hub"
  org_id         = "123456789012"
}
```

#### Folders

The projects under those folders, including ones created there later. A
project selected in Stream outside them shows as *No access*.

```hcl
module "scanner_hub_access" {
  source  = "streamsec-terraform/google-integration/streamsec//modules/volume-scanner-hub-access"
  version = "~> 2.22"

  hub_project_id = "my-scanner-hub"
  org_id         = "123456789012"
  grant_on       = { folder_ids = ["111111111111", "222222222222"] }
}
```

#### Projects

Those projects only, so IAM matches the projects selected in Stream exactly.
Add a project here when you select it in Stream, and remove it when you
deselect it.

```hcl
module "scanner_hub_access" {
  source  = "streamsec-terraform/google-integration/streamsec//modules/volume-scanner-hub-access"
  version = "~> 2.22"

  hub_project_id = "my-scanner-hub"
  org_id         = "123456789012"
  grant_on       = { project_ids = ["app-prod-123", "app-staging-456"] }
}
```

Folder and project IDs must be in the organization `org_id`: a role defined in
an organization can't be granted outside it. IDs are bare: `111111111111`, not
`folders/111111111111`. `gcloud projects get-ancestors <HUB_PROJECT_ID>` shows
the organization's ID.

A scanner deployed with a `name_suffix` has its own service account, such as
`streamsec-volume-scanner-stg@<hub project>.iam.gserviceaccount.com`. Pass it as
`scanner_service_account_email`.

### Who can run it

- **Every form:** Organization Role Administrator
  (`roles/iam.organizationRoleAdmin`) on the organization, to create and
  update the role.
- **To grant it,** one of:
  - organization: Organization Administrator
    (`roles/resourcemanager.organizationAdmin`) or Security Admin
    (`roles/iam.securityAdmin`) on the organization;
  - folders: Folder IAM Admin (`roles/resourcemanager.folderIamAdmin`) on each
    folder;
  - projects: Project IAM Admin (`roles/resourcemanager.projectIamAdmin`) on
    each project.

### What the grant allows

| Permissions | What the scanner does with them |
|---|---|
| `compute.instances.list`, `compute.instances.get`, `compute.disks.get` | Finds the project's VMs and their disks |
| `compute.disks.createSnapshot` | Snapshots each disk; the snapshot is stored in the hub |
| `resourcemanager.projects.get` | Checks its access to the project before scanning it, and reads the project number |
| `run.locations.list`, `run.services.list`, `run.revisions.get`, `run.jobs.list` | Lists Cloud Run services and jobs, and their images |
| `cloudfunctions.functions.list`, `cloudfunctions.functions.sourceCodeGet` | Lists gen1 Cloud Functions, and downloads their deployed source |
| `artifactregistry.repositories.downloadArtifacts` | Pulls the images of Cloud Run services, jobs and GKE pods |

None of them creates or deletes anything in the scanned projects. Everything
that does, such as the scan disks and the snapshot cleanup, is in the hub's own
project role, created by `modules/volume-scanner`.

**Security.** A grant on the organization makes the hub project as sensitive
as the organization. Anyone who can act as the hub's scanner service account,
or change what runs as it in the hub, can snapshot any disk in the
organization into the hub, read every gen1 Cloud Function's source, and pull
every Artifact Registry image. Folders or projects narrow that reach. The
projects you select in Stream decide what the scanner scans, but they do not
limit what IAM allows; grant on projects when the two must match.

**Not covered by this module:**

- Disks encrypted with customer-managed keys (CMEK): the hub's Compute Engine
  service agent needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on each key.
- VPC Service Controls: a perimeter around a scanned project that leaves out
  the hub blocks snapshots into the hub.

### If the console's command already ran

The console's command and this module create the same role, so in an
organization where the command already ran, the apply fails:

```
Custom project role organizations/<ORG_ID>/roles/streamsecVolumeScannerTarget already exists and must be imported
```

Import the role first. `scanner_hub_access` is the module's name in your
configuration:

```sh
terraform import 'module.scanner_hub_access.google_organization_iam_custom_role.target' organizations/<ORG_ID>/roles/streamsecVolumeScannerTarget
```

Or, on Terraform 1.5 or later, with an `import` block in your root module:

```hcl
import {
  to = module.scanner_hub_access.google_organization_iam_custom_role.target
  id = "organizations/<ORG_ID>/roles/streamsecVolumeScannerTarget"
}
```

Both set the same title, stage and permissions, and no description, so the
imported role has nothing to change. The bindings need no import: granting a
member that is already bound changes nothing, and Terraform manages the
binding from then on.

A binding the command made where this module doesn't grant stays, since
Terraform doesn't know about it. If the command granted on the organization
and you now grant on folders or projects, remove the organization binding
yourself, or the scanner keeps its access to the whole organization:

```sh
gcloud organizations remove-iam-policy-binding <ORG_ID> \
  --member=serviceAccount:streamsec-volume-scanner@<HUB_PROJECT_ID>.iam.gserviceaccount.com \
  --role=organizations/<ORG_ID>/roles/streamsecVolumeScannerTarget
```

For a folder, `gcloud resource-manager folders remove-iam-policy-binding <FOLDER_ID>`
takes the same `--member` and `--role`.

### Removing the access

`terraform destroy` removes the bindings and deletes the role. The hub's
scanner then reports each project it covers as *No access*, and scans only its
own project.

GCP keeps a deleted role for 7 days; an apply in that time undeletes it. After
that, the role's ID stays reserved for up to 30 more days, and creating it,
with this module or with the console's command, fails until then.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | >= 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_folder_iam_member.target](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/folder_iam_member) | resource |
| [google_organization_iam_custom_role.target](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/organization_iam_custom_role) | resource |
| [google_organization_iam_member.target](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/organization_iam_member) | resource |
| [google_project_iam_member.target](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_grant_on"></a> [grant\_on](#input\_grant\_on) | Where the role is granted, exactly one of: { organization = true }, the default, for every project of the organization, including ones created later; { folder\_ids = [...] } for the projects under those folders; or { project\_ids = [...] } for those projects only, so IAM matches the projects selected in Stream exactly. | <pre>object({<br>    organization = optional(bool, false)<br>    folder_ids   = optional(list(string), [])<br>    project_ids  = optional(list(string), [])<br>  })</pre> | <pre>{<br>  "organization": true<br>}</pre> | no |
| <a name="input_hub_project_id"></a> [hub\_project\_id](#input\_hub\_project\_id) | The hub: the project whose volume scanner, deployed by Stream with modules/volume-scanner, also scans other projects of the organization. | `string` | n/a | yes |
| <a name="input_org_id"></a> [org\_id](#input\_org\_id) | The organization's numeric ID. The custom role is defined there, and the folders and projects in grant\_on must belong to it. | `string` | n/a | yes |
| <a name="input_scanner_service_account_email"></a> [scanner\_service\_account\_email](#input\_scanner\_service\_account\_email) | The hub scanner's service account. Null, the default, means streamsec-volume-scanner@<hub\_project\_id>.iam.gserviceaccount.com, the one modules/volume-scanner creates. Set it for a scanner deployed with a name\_suffix, whose account ends in the suffix. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_granted_on"></a> [granted\_on](#output\_granted\_on) | Where the role is granted: scope is organization, folders or projects, and ids the organization ID, folder IDs or project IDs. |
| <a name="output_role_id"></a> [role\_id](#output\_role\_id) | ID of the organization custom role granted to the hub's scanner: streamsecVolumeScannerTarget. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | Full name of the custom role, organizations/<org\_id>/roles/streamsecVolumeScannerTarget, as IAM bindings name it. |
| <a name="output_scanner_service_account_email"></a> [scanner\_service\_account\_email](#output\_scanner\_service\_account\_email) | The hub scanner's service account the role is granted to. |
<!-- END_TF_DOCS -->
