# Stream Security — GCP Response Deployment

This example deploys Stream Security remediation Cloud Workflows to a single GCP project.

## What gets deployed

- Custom IAM roles (one per runbook) scoped to the project
- Service accounts bound to those roles
- Cloud Workflows for each remediation runbook

## Run

The environment variables below are pre-populated by the Stream Security UI.
Paste the command you copied, then run it:

```sh
terraform init
terraform apply -auto-approve
```

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
