terraform {
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
  }

  # Local state on purpose: this root creates the state bucket CI uses, and is applied
  # manually (never by CI) so the pipeline cannot change its own permissions.
  # *.tfstate is git-ignored; keep this directory's state file safe.
}
