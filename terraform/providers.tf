provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "shehujp-blog"
      ManagedBy   = "terraform"
      Environment = var.environment
      Repository  = "shehujp-blog"
    }
  }
}
