terraform {
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
  }

  # Local state for now (state is git-ignored). Planned: S3 backend with
  # encryption and versioning in a later stage.
}
