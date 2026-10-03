# Remote state in the S3 bucket created by terraform/bootstrap: versioned, encrypted,
# private, with S3-native locking (no DynamoDB table needed).
#
# The bucket name contains the AWS account ID, so it is NOT committed. Pass it at init time:
#   terraform init -backend-config="bucket=$(terraform -chdir=../../bootstrap output -raw state_bucket)"
# CI passes it from the TF_STATE_BUCKET repository secret.
terraform {
  backend "s3" {
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
