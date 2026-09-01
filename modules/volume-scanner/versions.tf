terraform {
  # 1.4, not the 1.0 the sibling modules declare: this one uses the
  # `terraform_data` managed resource, which was introduced in Terraform 1.4.
  required_version = ">= 1.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}
