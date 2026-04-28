# Stream Security — GCP Response Deployment

This example deploys Stream Security remediation Cloud Workflows to a single GCP project.

## What gets deployed

- Custom IAM roles (one per runbook) scoped to the project
- Service accounts bound to those roles
- Cloud Workflows for each remediation runbook

## Run

The Stream Security UI generates a ready-to-run command. Paste and run it in Cloud Shell:

```sh
export STREAMSEC_HOST=<value> && \
export STREAMSEC_API_TOKEN=<value> && \
export STREAMSEC_WORKSPACE_ID=<value> && \
export TF_VAR_project=<value> && \
export TF_VAR_region=<value> && \
terraform init && terraform apply -auto-approve
```

> **Note:** The `export` form is required. Inline env vars (`VAR=value terraform init && terraform apply`) only apply to the first command and will cause auth errors on `terraform apply`.

## Variables

| Variable | Description |
|----------|-------------|
| `TF_VAR_project` | GCP project ID |
| `TF_VAR_region` | GCP region for Cloud Workflows |

## Provider environment variables

| Variable | Description |
|----------|-------------|
| `STREAMSEC_HOST` | Stream Security API endpoint |
| `STREAMSEC_API_TOKEN` | Collection token for your GCP account |
| `STREAMSEC_WORKSPACE_ID` | Your Stream Security workspace ID |
