terraform {
  # bucket, region, and dynamodb_table are injected at `terraform init`
  # from GitHub Actions secrets: BACKEND_TF, AWS_REGION, DYNAMOTBALE_TF
  #
  # Local init:
  #   terraform init \
  #     -backend-config="bucket=$BACKEND_TF" \
  #     -backend-config="region=$AWS_REGION" \
  #     -backend-config="dynamodb_table=$DYNAMOTBALE_TF"
  backend "s3" {
    bucket  = "ec2-shutdown-lambda-bucket"
    key     = "ghost-blog/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}   
