# Remote state in the same private, versioned, encrypted bucket as the dev stack, under its OWN key. The pipeline's deploy role can
# only touch the dev/ prefix, so it can never read or change this stack: it is applied locally, on purpose.
#
# The bucket name contains the AWS account ID, so it is NOT committed. Pass it at init time:
#   terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket)"
terraform {
  backend "s3" {
    key          = "frontend/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
