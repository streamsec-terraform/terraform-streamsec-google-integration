# StreamForce Custom Plugin (GCP)

Deploys a Stream Security **StreamForce custom plugin** as a private, IAM-gated
Gen2 Cloud Function (Cloud Run) in your GCP project. Only the Stream Security
integration service account is granted `run.invoker`, so no anonymous internet
traffic can reach it. Environment values are passed straight into the function
and never pass through the Stream platform.

## Usage

Copy the block from the Stream Security plugin wizard — it is pre-filled with
your plugin id, package URL, callback token, integration service account, and
environment values.

```hcl
module "streamforce_plugin" {
  source = "streamsec-terraform/streamsec-google-integration//modules/streamforce-plugin"

  project_id       = "my-gcp-project"
  region           = "us-central1"
  plugin_id        = "6a4e3eff29e9d8a573640711"
  artifact_url     = "https://<stream-artifact-host>/plugins/<...>.zip"
  plugin_token     = var.plugin_token   # sensitive
  platform_url     = "https://acme.stream.security"
  invoker_sa_email = "stream-security@my-gcp-project.iam.gserviceaccount.com"

  plugin_env = {
    GITHUB_ORG   = "acme"
    GITHUB_TOKEN = var.github_token      # sensitive
  }
}
```

Then:

```sh
terraform init
terraform apply
```

The module requires `curl` on the machine (or Infrastructure Manager runner)
running Terraform — it stages the Stream-hosted plugin package into a bucket in
your project (Gen2 functions can only source from GCS) and posts the deployed
URL back to Stream Security.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
