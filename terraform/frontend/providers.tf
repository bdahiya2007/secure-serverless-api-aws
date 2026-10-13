# CloudFront certificates and web ACLs live in us-east-1.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project
      Component = "frontend"
      ManagedBy = "terraform"
    }
  }
}
