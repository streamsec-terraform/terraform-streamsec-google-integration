# StreamSecurity GCP Integration Scripts

Helper scripts for automated setup and teardown of the StreamSecurity GCP Integration
using [GCP Infrastructure Manager](https://cloud.google.com/infrastructure-manager/docs/overview).

## setup-prerequisites.sh

Automates the manual pre-integration steps required before deploying the StreamSecurity
Terraform module via Infrastructure Manager. The script is **idempotent** — safe to re-run
at any time.

### What it does

| Step | Description |
|------|-------------|
| 1 | Enables required GCP APIs and configures the project (org-policy override, Cloud Build SA permissions) |
| 2 | Creates two custom IAM roles: an **ops role** (IAM, logging, resource management) always created at organization level, and a **project resources role** (pubsub, secrets, functions) always created at project level. |
| 3 | Creates a service account for Infrastructure Manager in the target project |
| 4 | Grants both custom roles and `roles/config.agent` to the service account at organization level |
| 5 | Creates the StreamSecurity credentials secret in Secret Manager |
| 6 | Auto-detects the latest release tag, creates an Infrastructure Manager preview deployment, and monitors it until completion |

### Modes

**Organization mode (default):**
- Ops role created at the organization level.
- IAM bindings granted at the organization level.
- Creates organization-level logging sink (aggregates logs from all projects).
- Requires `--org-id` and organization-level permissions.

**Single-project mode (`--single-project`):**
- Ops role still created at the organization level (Terraform requires org-level permissions).
- IAM bindings still granted at the organization level.
- Creates project-level logging sink instead (logs only from the specified project).
- Passes `include_projects` to Terraform to scope asset discovery to a single project.
- Requires `--org-id` and organization-level permissions (same as org mode).
- Use this mode to minimize scope of log collection and asset discovery, not to avoid org-level permissions.

**Project-only mode (`--project-only`):**
- Same scope as single-project mode (one project, project-level logging sink).
- **No organization-level permissions required.** Ops role, runner SA bindings and
  `roles/config.agent` are all created at the project level.
- The Stream Security service account gets `roles/viewer` + `roles/iam.securityReviewer`
  on the project only (`sa_project_level_permissions=true`), so organization- and
  folder-level IAM is not collected.
- `--org-id` is optional. Project `roles/owner` is sufficient (see Prerequisites for the
  Editor-based alternative).
- Use this mode when the person running the script cannot get organization-level access.
  To cover more projects, run the script once per project.
- When resuming with `--start-from-step`, pass `--project-only` again.

### Prerequisites

- **gcloud CLI** installed and authenticated (`gcloud auth login`)
- **Organization-level permissions** (org and single-project modes; not needed with `--project-only`), choose one:
  - `roles/owner` (simplest)
  - `roles/iam.organizationRoleAdmin` **+** `roles/resourcemanager.organizationAdmin` (both required)
- **Project-level permissions** (choose one):
  - `roles/owner` or `roles/editor` (recommended)
  - Minimal: `roles/serviceusage.serviceUsageAdmin` + `roles/iam.serviceAccountAdmin` + `roles/secretmanager.admin` + `roles/config.admin`
- The script will auto-grant `roles/orgpolicy.policyAdmin` if needed to disable the
  `iam.disableServiceAccountKeyCreation` constraint at the project level
  (granted at the project level in `--project-only` mode). If that constraint is
  enforced and the grant fails, an organization admin must lift it on the project.
- `--project-only` mode: `roles/owner` on the project, or `roles/editor` +
  `roles/iam.roleAdmin` + `roles/resourcemanager.projectIamAdmin` (custom roles and
  project IAM policy are needed; `roles/editor` alone is not enough).

> **Note:** In org mode, `roles/resourcemanager.organizationAdmin` alone is **not**
> sufficient — it allows setting IAM policies but cannot create custom roles. You need
> `roles/iam.organizationRoleAdmin` as well.

### Usage

```bash
# Organization mode (default):
./setup-prerequisites.sh \
    --org-id <ORGANIZATION_ID> \
    --project-id <PROJECT_ID> \
    --region <REGION> \
    --streamsec-host <HOST> \
    --workspace-id <WORKSPACE_ID> \
    --api-token <API_TOKEN>
```

### Required flags

| Flag | Env var | Description |
|------|---------|-------------|
| `--project-id` | `PROJECT_ID` | GCP project for the Infrastructure Manager deployment |
| `--org-id` | `ORGANIZATION_ID` | GCP organization ID (always required) |
| `--region` | `REGION` | GCP region (e.g. `us-central1`) |
| `--streamsec-host` | `STREAMSEC_HOST` | StreamSecurity host (e.g. `your-org.streamsec.io`) |
| `--workspace-id` | `WORKSPACE_ID` | StreamSecurity workspace ID |
| `--api-token` | `API_TOKEN` | StreamSecurity API token |

### Optional flags

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--ops-role-id` | `CUSTOM_ROLE_ID` | `StreamSecurityInfraManagerOpsRole` | Ops custom role ID |
| `--custom-role-id` | | | Alias for `--ops-role-id` |
| `--project-role-id` | `PROJECT_ROLE_ID` | `StreamSecurityInfraManagerProjectRole` | Project resources custom role ID |
| `--sa-name` | `SA_NAME` | `StreamSecurityInfraManagerSa` | Service account name |
| `--secret-name` | `SECRET_NAME` | `streamsec-credentials` | Secret Manager secret name |
| `--deployment-name` | `DEPLOYMENT_NAME` | `streamsec-integration` | IM deployment name |
| `--git-ref` | `GIT_REF` | latest release | Module git ref (tag or branch) used for the preview |
| `--single-project` | `SINGLE_PROJECT=true` | — | Project-level logging sink + scoped asset discovery (still requires org-level permissions) |
| `--project-only` | `PROJECT_ONLY=true` | — | Like `--single-project`, but everything at project level; no org permissions, `--org-id` optional |
| `--start-from-step` | `START_FROM_STEP` | `1` | Resume from a specific step (1-6) |
| `--skip-permission-check` | `SKIP_PERMISSION_CHECK=true` | — | Skip upfront permission validation |
| `-y`, `--yes` | `AUTO_CONFIRM=true` | — | Skip all confirmation prompts |

### Examples

**Full setup (org mode, default):**

```bash
./setup-prerequisites.sh \
    --org-id 123456789 \
    --project-id my-gcp-project \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id 6a3f9c1e8b7d4f0a2c5e9b1d \
    --api-token bLq9K84_zdRT921xkJfaQWpr6YHUtiox73NMbvCe2td
```

**Single-project mode (project-level sink + scoped asset discovery):**

```bash
./setup-prerequisites.sh \
    --org-id 123456789 \
    --project-id my-gcp-project \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id 6a3f9c1e8b7d4f0a2c5e9b1d \
    --api-token bLq9K84_zdRT921xkJfaQWpr6YHUtiox73NMbvCe2td \
    --single-project
```

**Project-only mode (no organization-level permissions):**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id 6a3f9c1e8b7d4f0a2c5e9b1d \
    --api-token bLq9K84_zdRT921xkJfaQWpr6YHUtiox73NMbvCe2td \
    --project-only
```

### After the script completes

If the preview succeeded, create the deployment from the preview in the
[GCP Console](https://console.cloud.google.com/infra-manager/deployments)
(Infrastructure Manager → Previews → select the preview → Create Deployment).

---

## cleanup-abandoned-deployment.sh

> **Important:** This script does **NOT** remove the Infrastructure Manager deployment itself.
> It only cleans up Terraform-managed resources (Cloud Functions, Pub/Sub topics, log sinks,
> service accounts, etc.) that remain after the deployment is deleted with `--delete-policy=abandon`.

### When to use this script

Use this script when:
- An Infrastructure Manager deployment fails and you cannot delete it normally
- You deleted an IM deployment with `--delete-policy=abandon` and need to clean up orphaned resources
- You need to remove all integration resources before re-deploying

### Complete cleanup workflow

**Step 1: Delete the Infrastructure Manager deployment**

```bash
gcloud infra-manager deployments delete <DEPLOYMENT_NAME> \
  --project=<PROJECT_ID> \
  --location=<REGION> \
  --delete-policy=abandon
```

**Step 2: Run the cleanup script**

The script auto-detects which resources exist and removes:
- Terraform-managed resources (functions, sinks, topics, secrets, service accounts)
- Custom IAM roles created by `setup-prerequisites.sh`
- IAM bindings for the Infrastructure Manager service account
- The Infrastructure Manager service account itself

**Step 3: Manually delete regional secret (gcloud CLI limitation)**

> **Known Limitation:** The gcloud CLI cannot delete regional secrets. You must manually
> delete the `stream-security` regional secret from the
> [GCP Console → Secret Manager → Regional secrets](https://console.cloud.google.com/security/secret-manager).

---

### Usage

**Cleanup a deployment (with org-level resources):**

```bash
./cleanup-abandoned-deployment.sh \
    --org-id 123456789 \
    --project-id my-gcp-project \
    --region us-central1
```

**Cleanup a deployment (skip org-level resources):**

```bash
./cleanup-abandoned-deployment.sh \
    --project-id my-gcp-project \
    --region us-central1
```

> **Note:** `--org-id` is optional. When provided, the script will also clean up
> org-level resources (custom IAM roles, IAM bindings). When omitted, only project-level
> resources are removed. The script auto-detects which resources exist before attempting
> deletion.

Run with `--help` for the full list of optional overrides (resource names, `-y` for
non-interactive mode, etc.).
