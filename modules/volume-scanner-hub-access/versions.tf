terraform {
  # 1.3, not the 1.0 the sibling modules declare: grant_on's optional()
  # attributes with defaults were introduced in Terraform 1.3.
  required_version = ">= 1.3"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}
