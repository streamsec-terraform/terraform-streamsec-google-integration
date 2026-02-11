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
| 2 | Creates two custom IAM roles: an **ops role** (IAM, logging, resource management) and a **project resources role** (pubsub, secrets, functions). In org mode the ops role is created at the organization level; in single-project mode both roles are created at the project level. |
| 3 | Creates a service account for Infrastructure Manager in the target project |
| 4 | Grants both custom roles and `roles/config.agent` to the service account (at org or project level depending on mode) |
| 5 | Creates the StreamSecurity credentials secret in Secret Manager |
| 6 | Auto-detects the latest release tag, creates an Infrastructure Manager preview deployment, and monitors it until completion |

### Modes

**Organization mode (default):**
- Ops role created at the organization level (includes org-scoped permissions like
  `resourcemanager.organizations.*`).
- IAM bindings granted at the organization level.
- Requires `--org-id` and organization-level permissions.

**Single-project mode (`--single-project`):**
- Both roles created at the project level (no org access needed).
- IAM bindings granted at the project level.
- `--org-id` is optional.
- Ideal for users who do not have organization-level permissions.

### Prerequisites

- **gcloud CLI** installed and authenticated (`gcloud auth login`)
- **Organization mode** — Organization-level permissions (choose one):
  - `roles/owner` (simplest)
  - `roles/iam.organizationRoleAdmin` **+** `roles/resourcemanager.organizationAdmin` (both required)
- **Single-project mode** — no organization-level permissions needed.
- **Project-level permissions** (choose one):
  - `roles/owner` or `roles/editor` (recommended)
  - Minimal: `roles/serviceusage.serviceUsageAdmin` + `roles/iam.serviceAccountAdmin` + `roles/secretmanager.admin` + `roles/config.admin`
- The script will auto-grant `roles/orgpolicy.policyAdmin` if needed to disable the
  `iam.disableServiceAccountKeyCreation` constraint at the project level.

> **Note:** In org mode, `roles/resourcemanager.organizationAdmin` alone is **not**
> sufficient — it allows setting IAM policies but cannot create custom roles. You need
> `roles/iam.organizationRoleAdmin` as well.

### Usage

```bash
# Organization mode (default):
./setup-prerequisites.sh \
    --project-id <PROJECT_ID> \
    --org-id <ORGANIZATION_ID> \
    --region <REGION> \
    --streamsec-host <HOST> \
    --workspace-id <WORKSPACE_ID> \
    --api-token <API_TOKEN>

# Single-project mode (no org access needed):
./setup-prerequisites.sh \
    --single-project \
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
| `--org-id` | `ORGANIZATION_ID` | GCP organization ID (required for org mode; optional with `--single-project`) |
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
| `--single-project` | `SINGLE_PROJECT=true` | — | All roles at project level — no org access needed |
| `--start-from-step` | `START_FROM_STEP` | `1` | Resume from a specific step (1-6) |
| `--skip-permission-check` | `SKIP_PERMISSION_CHECK=true` | — | Skip upfront permission validation |
| `-y`, `--yes` | `AUTO_CONFIRM=true` | — | Skip all confirmation prompts |

### Examples

**Full setup (org mode, default):**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789
```

**Single-project mode (no org access needed):**

```bash
./setup-prerequisites.sh \
    --single-project \
    --project-id my-gcp-project \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789
```

**Resume from Step 6 after fixing a permission issue:**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789 \
    --start-from-step 6
```

**Non-interactive (CI/CD):**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789 \
    -y
```

### After the script completes

If the preview succeeded, the script prints a ready-to-use `gcloud infra-manager deployments apply` command.
You can also create the deployment from the
[GCP Console](https://console.cloud.google.com/infra-manager/deployments).

---

## cleanup-abandoned-deployment.sh

Removes GCP resources left behind after an Infrastructure Manager deployment was deleted
with `--delete-policy=abandon` (or after a partial apply). The script auto-detects which
resources exist and only attempts to delete those that are present.

In addition to Terraform-managed resources (functions, sinks, topics, secrets, service
accounts), the cleanup script also detects and removes the custom IAM roles and IM
service account created by `setup-prerequisites.sh`.

### Examples

**Cleanup an org-level deployment:**

```bash
./cleanup-abandoned-deployment.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1
```

**Cleanup a single-project deployment:**

```bash
./cleanup-abandoned-deployment.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1
```

> **Note:** The cleanup script always requires `--org-id` because it auto-detects
> whether resources were deployed at the org or project level and cleans up both.

Run with `--help` for the full list of optional overrides (resource names, `-y` for
non-interactive mode, etc.).
