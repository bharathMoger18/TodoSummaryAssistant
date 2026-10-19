terraform {
  required_version = ">= 1.10"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }

    # State lives in S3 so any pipeline pod can reach it. Bucket and key are passed at init time.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "todo-summary-assistant"
      ManagedBy = "terraform"
    }
  }
}
