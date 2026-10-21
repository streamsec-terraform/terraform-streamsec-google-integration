# Stream Security — GCP hub volume scanner: access to other projects

Gives a hub's volume scanner access to the other projects of the organization
with your own Terraform, instead of the gcloud command Stream's console
renders. The [module README](../../modules/volume-scanner-hub-access/README.md)
says which rights you need, what the grant allows, and what to do if the
console's command already ran in the organization.

## Run

After the hub's volume scanner is deployed, as an organization admin:

```sh
gcloud auth application-default login
terraform init
terraform apply -var=hub_project_id=<HUB_PROJECT_ID> -var=org_id=<ORG_ID>
```

`gcloud projects get-ancestors <HUB_PROJECT_ID>` shows the organization's ID.
To grant on folders or projects instead of the whole organization, set
`grant_on` in `main.tf`.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
