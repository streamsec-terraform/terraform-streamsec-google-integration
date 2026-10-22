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
| 2 | Creates two custom IAM roles: an **ops role** (IAM, logging, resource management) at organization level (project level with `--project-only`), and a **project resources role** (pubsub, secrets, functions) at project level. |
| 3 | Creates a service account for Infrastructure Manager in the target project |
| 4 | Grants both custom roles and `roles/config.agent` to the service account (organization level, or project level with `--project-only`) |
| 5 | Creates the StreamSecurity credentials secret in Secret Manager |
| | [Leftover check](#leftover-check): stops before the preview if an earlier integration left resources under the module's fixed names |
| 6 | Uses the latest release tag (or `--git-ref`), creates an Infrastructure Manager preview deployment, and monitors it until completion |

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

**GKE audit logs (`--enable-gke-logs`):** the flag sets `enable_gke_logs=true` in the preview (other inputs are kept); the next steps tell you to set it on the deployment. Before the preview the script stops if the module ref has no real-time GKE module, or if the project role lacks the `run.services.*` permissions that step 2 adds.

### Prerequisites

- **gcloud CLI** installed and authenticated (`gcloud auth login`)
- **Organization-level permissions** (org and single-project modes; not needed with `--project-only`), choose one:
  - `roles/owner` (simplest)
  - `roles/iam.organizationRoleAdmin` **+** `roles/resourcemanager.organizationAdmin` (both required)
- **Project-level permissions** (choose one):
  - `roles/owner` or `roles/editor` (recommended)
  - Minimal: `roles/serviceusage.serviceUsageAdmin` + `roles/iam.serviceAccountAdmin` + `roles/secretmanager.admin` + `roles/config.admin`
- The script will auto-grant `roles/orgpolicy.policyAdmin` if needed to disable the
  `iam.disableServiceAccountKeyCreation` constraint at the project level. In
  `--project-only` mode it does **not** self-grant: if the constraint is enforced on
  the project and you cannot set org policy there, the script stops before making
  changes and prints the command an organization admin must run.
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
| `--org-id` | `ORGANIZATION_ID` | GCP organization ID (required unless `--project-only`) |
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
| `--git-ref` | `GIT_REF` | latest release | Module git ref used for the preview: a tag or a slash-free ref (Infrastructure Manager cannot fetch refs containing `/`, so `feature/x` style branch names are rejected) |
| `--single-project` | `SINGLE_PROJECT=true` | — | Project-level logging sink + scoped asset discovery (still requires org-level permissions) |
| `--project-only` | `PROJECT_ONLY=true` | — | Like `--single-project`, but everything at project level; no org permissions, `--org-id` optional |
| `--enable-gke-logs` | `ENABLE_GKE_LOGS=true` | — | Collect GKE audit logs in real time (see [Modes](#modes)) |
| `--start-from-step` | `START_FROM_STEP` | `1` | Resume from a specific step (1-6) |
| `--check-leftovers` | `CHECK_LEFTOVERS=true` | — | Run only the [leftover check](#leftover-check): read-only, unless with `--cleanup-leftovers`. Needs only `--project-id`, `--region`, the mode flags and `--org-id` (unless `--project-only`) |
| `--cleanup-leftovers` | — | — | Delete the leftovers the check finds, after a confirmation, then go on |
| `--skip-leftover-check` | — | — | Don't run the leftover check |
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
    --workspace-id <WORKSPACE_ID> \
    --api-token <API_TOKEN>
```

**Single-project mode (project-level sink + scoped asset discovery):**

```bash
./setup-prerequisites.sh \
    --org-id 123456789 \
    --project-id my-gcp-project \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id <WORKSPACE_ID> \
    --api-token <API_TOKEN> \
    --single-project
```

**Project-only mode (no organization-level permissions):**

```bash
./setup-prerequisites.sh \
    --project-id my-gcp-project \
    --region us-central1 \
    --streamsec-host app.streamsec.io \
    --workspace-id <WORKSPACE_ID> \
    --api-token <API_TOKEN> \
    --project-only
```

### Leftover check

A project that had the integration before can keep some of its resources after a
partial removal. The preview doesn't notice them, but the apply fails on them with
409 "already exists", and Infrastructure Manager can't adopt them: re-applying with
`--import-existing-resources` fails with `found unsupported type for importing:
google_pubsub_topic`.

So before step 6 the script looks for the resources the apply creates under fixed
names (the names are in [`lib/integration-resources.sh`](lib/integration-resources.sh)):

- the Pub/Sub topic and the logging sink (organization-level in organization mode, project-level otherwise)
- the events Cloud Function
- the function service account and the `stream-security` service account
- the regional `stream-security` secret
- with `--enable-gke-logs`: the GKE function, sink, topic and service account, and the `streamsec-gke-logs-token` secret

A resource in the state of any Infrastructure Manager deployment in the project belongs
to it, whatever the deployment is called: re-running the script on an integrated
project finds no leftovers. (If the owner isn't `--deployment-name`, the script says
so: apply the preview to that deployment.) Anything else that exists is printed with
hints for judging whether it is safe to delete (subscriptions, IAM bindings,
user-managed keys, the function's trigger, the sink's destination), and the script
stops before the preview with two ways forward:

- run `cleanup-abandoned-deployment.sh` with the printed `--only` command, then re-run
  this script (`--start-from-step 6` if steps 1-5 are done), or
- re-run this script with `--cleanup-leftovers`: it deletes the same resources after a
  confirmation and goes on to the preview. An organization-level sink takes typing
  `DELETE-ORG-RESOURCES`. `--yes` skips the confirmation, but then deletes nothing if
  any leftover looks in use (a topic with subscriptions, a service account with
  user-managed keys, a secret with IAM bindings). A whole abandoned integration looks
  in use too, so confirm it interactively or use the cleanup script.

These resources are only leftovers if nothing else manages them: a project integrated
with plain Terraform, or by a deployment in another project, shows the same table.
Check the hints before deleting. A leftover sink that writes to another project is
never deleted (it may serve a live integration there); the script prints the command
to delete it by hand.

To check a project without changing anything:

```bash
./setup-prerequisites.sh --project-only --project-id my-gcp-project --region us-central1 --check-leftovers
```

It exits non-zero when it finds leftovers, or when the project's deployments can't be
read (including a location Infrastructure Manager can't reach) or one of them is still
applying. A resource it has no permission to read is
listed as `?` with a warning, without stopping the run. `--skip-leftover-check` skips
the check, e.g. while an unrelated deployment is stuck.

### After the script completes

If the preview succeeded, create the deployment from the preview in the
[GCP Console](https://console.cloud.google.com/infra-manager/deployments)
(Infrastructure Manager → Previews → select the preview → Create Deployment).

### Updating an existing integration

Re-run the script with the same flags used at onboarding. When the deployment
(`--deployment-name`, default `streamsec-integration`) already exists, the script updates the
IAM roles, previews an update of that deployment to the latest release, and prints the Console
steps to apply it: open the deployment, click **Edit**, set the Git ref to the new release, keep
all other values, and click **Update**.

A Console update alone is not enough when a release adds deployer permissions; re-running the
script applies them first.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| The preview succeeds, but the deployment apply fails with `Error 409` / `already exists` on `stream-security-events-topic`, `stream-security-function-sa` or another `stream-security-*` resource. Re-applying with `--import-existing-resources` fails with `found unsupported type for importing: google_pubsub_topic`. | Leftovers of an earlier integration. Previews don't check whether resources exist, and Infrastructure Manager can't import them. | Run `./setup-prerequisites.sh ... --check-leftovers` with the same mode flags, then delete what it lists (see [Leftover check](#leftover-check)) and re-apply the deployment. Resources the failed apply created itself are in its state, so they aren't listed. |

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
- Terraform-managed resources (functions, sinks, topics, secrets including the regional
  `stream-security` secret, service accounts)
- Custom IAM roles created by `setup-prerequisites.sh`
- IAM bindings for the Infrastructure Manager service account
- The Infrastructure Manager service account itself

Regional secrets are only served by the regional Secret Manager endpoint
(`secretmanager.<region>.rep.googleapis.com`), which the script uses for them.

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

**Delete only some Terraform-managed resources** (what `setup-prerequisites.sh`'s
[leftover check](#leftover-check) prints): `--only` takes a comma-separated list of
`events-function`, `org-sink`, `project-sink`, `topic`,
`global-secret`, `regional-secret`, `function-sa` and `sa`, and leaves the
Infrastructure Manager service account, its bindings and the custom roles alone.

```bash
./cleanup-abandoned-deployment.sh \
    --project-id my-gcp-project \
    --region us-central1 \
    --only topic,function-sa
```

Run with `--help` for the full list of optional overrides (resource names, `-y` for
non-interactive mode, etc.).

---

## Tests

`tests/` runs both scripts against a fake `gcloud` and `curl` (`tests/bin`), with
[bats](https://github.com/bats-core/bats-core). From the repository root:

```bash
docker run --rm -v "$PWD/scripts:/code" bats/bats:1.11.1 /code/tests
```
