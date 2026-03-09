terraform {
  # S3 remote state with DynamoDB locking.
  # bucket, region, and dynamodb_table are never hardcoded here — they are
  # injected at `terraform init` time from GitHub Actions secrets:
  #
  #   Secret name              Maps to
  #   ─────────────────────    ─────────────────────────────
  #   TF_STATE_BUCKET          -backend-config="bucket=..."
  #   TF_STATE_REGION          -backend-config="region=..."
  #   TF_STATE_LOCK_TABLE      -backend-config="dynamodb_table=..."
  #
  # Local init (replace <...> with the values from your GitHub secrets):
  #   terraform init \
  #     -backend-config="bucket=<TF_STATE_BUCKET>" \
  #     -backend-config="region=<TF_STATE_REGION>" \
  #     -backend-config="dynamodb_table=<TF_STATE_LOCK_TABLE>"
  backend "s3" {
    key     = "ghost-blog/terraform.tfstate"
    encrypt = true
  }
}
