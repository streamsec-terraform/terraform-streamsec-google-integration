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
| 2 | Creates a custom organization-level IAM role with the permissions needed by Infrastructure Manager |
| 3 | Creates a service account for Infrastructure Manager in the target project |
| 4 | Grants the custom role and `roles/config.agent` to the service account at org level |
| 5 | Creates the StreamSecurity credentials secret in Secret Manager |
| 6 | Auto-detects the latest release tag, creates an Infrastructure Manager preview deployment, and monitors it until completion |

### Prerequisites

- **gcloud CLI** installed and authenticated (`gcloud auth login`)
- **Organization-level permissions** (choose one):
  - `roles/owner` (simplest)
  - `roles/iam.organizationRoleAdmin` **+** `roles/resourcemanager.organizationAdmin` (both required)
- **Project-level permissions** (choose one):
  - `roles/owner` or `roles/editor` (recommended)
  - Minimal: `roles/serviceusage.serviceUsageAdmin` + `roles/iam.serviceAccountAdmin` + `roles/secretmanager.admin` + `roles/config.admin`
- The script will auto-grant `roles/orgpolicy.policyAdmin` if needed to disable the
  `iam.disableServiceAccountKeyCreation` constraint at the project level.

> **Note:** `roles/resourcemanager.organizationAdmin` alone is **not** sufficient — it
> allows setting IAM policies but cannot create custom roles. You need
> `roles/iam.organizationRoleAdmin` as well.

### Usage

```bash
./setup-prerequisites.sh \
    --project-id <PROJECT_ID> \
    --org-id <ORGANIZATION_ID> \
    --region <REGION> \
    --streamsec-host <HOST> \
    --workspace-id <WORKSPACE_ID> \
    --api-token <API_TOKEN>
```

### Required flags

| Flag | Env var | Description |
|------|---------|-------------|
| `--project-id` | `PROJECT_ID` | GCP project for the Infrastructure Manager deployment |
| `--org-id` | `ORGANIZATION_ID` | GCP organization ID |
| `--region` | `REGION` | GCP region (e.g. `us-central1`) |
| `--streamsec-host` | `STREAMSEC_HOST` | StreamSecurity host (e.g. `your-org.streamsec.io`) |
| `--workspace-id` | `WORKSPACE_ID` | StreamSecurity workspace ID |
| `--api-token` | `API_TOKEN` | StreamSecurity API token |

### Optional flags

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--custom-role-id` | `CUSTOM_ROLE_ID` | `StreamSecurityInfraManagerRole` | Custom IAM role ID |
| `--sa-name` | `SA_NAME` | `StreamSecurityInfraManagerSa` | Service account name |
| `--secret-name` | `SECRET_NAME` | `streamsec-credentials` | Secret Manager secret name |
| `--deployment-name` | `DEPLOYMENT_NAME` | `streamsec-integration` | IM deployment name |
| `--single-project` | `ORG_LEVEL_SINK=false` | — | Use per-project log sinks instead of a single org-level sink |
| `--start-from-step` | `START_FROM_STEP` | `1` | Resume from a specific step (1-6) |
| `--skip-permission-check` | `SKIP_PERMISSION_CHECK=true` | — | Skip upfront permission validation |
| `-y`, `--yes` | `AUTO_CONFIRM=true` | — | Skip all confirmation prompts |

### Examples

**Full setup (org-level sink, default):**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789
```

**Single-project mode (per-project log sinks):**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1 \
    --single-project \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789
```

**Resume from Step 4 after fixing a permission issue:**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --org-id 123456789 \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id ws-abc123 \
    --api-token tok-xyz789 \
    --start-from-step 4
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

### Usage

```bash
./cleanup-abandoned-deployment.sh \
    --project-id <PROJECT_ID> \
    --org-id <ORGANIZATION_ID> \
    --region <REGION>
```

Run with `--help` for the full list of optional overrides (resource names, `-y` for
non-interactive mode, etc.).
